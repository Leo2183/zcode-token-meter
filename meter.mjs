// meter.mjs — token-meter 悬浮窗数据层
// 从 ~/.zcode/cli/db/db.sqlite 只读轮询,产出与 turn-summary.mjs 同语义的快照。
// 独立于 Electron,可用 `node meter.mjs` 直接验证。

import { DatabaseSync } from 'node:sqlite';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

export function defaultDbPath() {
  return process.env.ZCODE_METER_DB || path.join(homedir(), '.zcode', 'cli', 'db', 'db.sqlite');
}

const ctxLimit = () => Number(process.env.ZCODE_TOKEN_METER_CTX_LIMIT || 1000000);

// 单条请求的解码速度:output / (duration - ttft)
function rowTps(r) {
  const decodeMs = Math.max(0, (r.duration_ms || 0) - (r.time_to_first_token_ms ?? 0));
  return decodeMs > 0 && r.output_tokens ? r.output_tokens / (decodeMs / 1000) : null;
}

export function collectSnapshot(dbPath = defaultDbPath()) {
  if (!existsSync(dbPath)) return { ok: false, reason: 'no-db' };
  let db;
  try { db = new DatabaseSync(dbPath, { readOnly: true }); }
  catch (e) { return { ok: false, reason: 'open-failed: ' + e.message }; }

  try {
    // 会话跟随:取 time_updated 最新的顶层(非子代理、未归档)会话。
    // session.time_updated 在消息/工具等事件落库时就会刷新,不必等模型请求完成——
    // 切换对话后一旦有输入即跟随;找不到时退回旧行为(最新 main_turn 所在会话)。
    // 双重检测:
    //   当前对话 = 最近一次"用户亲手输入"(input_history)所在的顶层会话——
    //              定时/后台会话的周期触发不写 input_history,抢不走显示;
    //   活跃对话 = time_updated 最新的顶层会话(含定时任务),与当前对话不同时作为 otherActive 提示。
    const curInput = db.prepare(
      `SELECT h.session_id FROM input_history h JOIN session s ON s.id = h.session_id
       WHERE h.session_id IS NOT NULL AND s.parent_id IS NULL AND s.time_archived IS NULL
         AND s.id NOT LIKE '%subagent%'
       ORDER BY h.time_created DESC LIMIT 1`
    ).get();
    const active = db.prepare(
      `SELECT id, title, time_updated FROM session
       WHERE parent_id IS NULL AND time_archived IS NULL AND id NOT LIKE '%subagent%'
       ORDER BY time_updated DESC LIMIT 1`
    ).get();
    const sid = (curInput && curInput.session_id)
      || (active && active.id)
      || db.prepare("SELECT session_id FROM model_usage WHERE query_source='main_turn' ORDER BY started_at DESC LIMIT 1").get()?.session_id
      || null;
    if (!sid) return { ok: true, empty: true };
    const otherActive = active && active.id !== sid
      ? { id: active.id, title: (active.title || active.id.slice(5, 17)).slice(0, 40), agoMs: Date.now() - active.time_updated }
      : null;

    const lastTurnId = db.prepare(
      "SELECT turn_id FROM model_usage WHERE session_id=? AND query_source='main_turn' ORDER BY started_at DESC LIMIT 1"
    ).get(sid)?.turn_id;
    if (!lastTurnId) return { ok: true, empty: true, session: { id: sid, model: null } }; // 刚切到的新会话尚无请求
    const rows = db.prepare(
      `SELECT id, started_at, duration_ms, time_to_first_token_ms, status,
              input_tokens, output_tokens, cache_read_input_tokens, model_id, tool_call_count
       FROM model_usage WHERE session_id=? AND turn_id=? AND query_source='main_turn' ORDER BY started_at ASC`
    ).all(sid, lastTurnId);

    const done = rows.filter(r => r.status === 'completed');
    const ttfts = done.map(r => r.time_to_first_token_ms).filter(v => v != null);
    const out = done.reduce((a, r) => a + (r.output_tokens || 0), 0);
    const decodeMs = done.reduce((a, r) => a + Math.max(0, (r.duration_ms || 0) - (r.time_to_first_token_ms ?? 0)), 0);

    const last = rows[rows.length - 1];
    const ctxTokens = last.input_tokens;
    const cacheRate = ctxTokens > 0 && last.cache_read_input_tokens != null
      ? last.cache_read_input_tokens / ctxTokens : null;

    const cum = db.prepare(
      `SELECT COALESCE(SUM(input_tokens),0) in_t, COALESCE(SUM(cache_read_input_tokens),0) cache_t,
              COALESCE(SUM(CASE WHEN status='completed' THEN output_tokens ELSE 0 END),0) out_t
       FROM model_usage WHERE session_id=? AND query_source='main_turn'`
    ).get(sid);

    // 最近 24 轮(main_turn)的每轮消耗,按三层分解:命中(缓存读)/未命中(新处理)/输出
    const turns = db.prepare(
      `SELECT COALESCE(SUM(cache_read_input_tokens),0) hit,
              COALESCE(SUM(input_tokens),0) - COALESCE(SUM(cache_read_input_tokens),0) miss,
              COALESCE(SUM(CASE WHEN status='completed' THEN output_tokens ELSE 0 END),0) out
       FROM model_usage WHERE session_id=? AND query_source='main_turn'
       GROUP BY turn_id ORDER BY MAX(started_at) DESC LIMIT 24`
    ).all(sid).reverse();

    return {
      ok: true, ts: Date.now(),
      session: { id: sid, model: last.model_id || null },
      turn: {
        id: lastTurnId,
        requests: rows.length,
        done: done.length,
        ttftMs: ttfts.length ? Math.min(...ttfts) : null,
        tps: decodeMs > 0 ? out / (decodeMs / 1000) : null,
        outTokens: out,
        lastStatus: last.status,
        lastAt: last.started_at,
        lastId: last.id,
      },
      ctx: { tokens: ctxTokens, limit: ctxLimit(), cacheRate },
      cum: { in: cum.in_t, cache: cum.cache_t, out: cum.out_t, total: cum.in_t + cum.out_t },
      last: {
        status: last.status, ttftMs: last.time_to_first_token_ms, tps: rowTps(last),
        outTokens: last.output_tokens, toolCalls: last.tool_call_count,
      },
      turns,
      otherActive,
    };
  } catch (e) {
    return { ok: false, reason: e.message };
  } finally {
    try { db.close(); } catch {}
  }
}

// 直接运行时打印 JSON,便于验证与降级轮询复用
if (process.argv[1] && process.argv[1].endsWith('meter.mjs')) {
  console.log(JSON.stringify(collectSnapshot()));
}
