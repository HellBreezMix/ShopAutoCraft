export default {
  async fetch(request, env, ctx) {
    try {
      // ===== GET — веб-панель со статусом (открывается из обычного браузера,
      // не из OC — поэтому не попадает под ту же блокировку Cloudflare,
      // что раньше ловили GET-запросы от Java-клиента компьютера) =====
      if (request.method === "GET") {
        return await renderDashboard(env);
      }

      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405 });
      }

      const bodyText = await request.text();
      let bodyObj = null;
      try { bodyObj = JSON.parse(bodyText); } catch (e) { /* не JSON — обычное уведомление */ }

      // ===== ОПРОС КОМАНД: тело вида {"after": "..."} =====
      if (bodyObj && Object.prototype.hasOwnProperty.call(bodyObj, "after")) {
        if (env.STATE) {
          ctx.waitUntil(env.STATE.put("lastSeen", String(Date.now())));
        }

        let afterParam = String(bodyObj.after || "0");
        const isColdStart = !afterParam || afterParam === "0";

        const discordUrl = isColdStart
          ? "https://discord.com/api/v10/channels/" + env.DISCORD_CHANNEL_ID + "/messages?limit=1"
          : "https://discord.com/api/v10/channels/" + env.DISCORD_CHANNEL_ID +
            "/messages?after=" + afterParam + "&limit=20";

        const resp = await fetch(discordUrl, {
          headers: { "Authorization": "Bot " + env.DISCORD_BOT_TOKEN },
        });

        if (!resp.ok) {
          return new Response(JSON.stringify({ commands: [], lastId: afterParam, error: "Discord API " + resp.status }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }

        const messages = await resp.json();

        let maxId = afterParam;
        for (const m of messages) {
          if (BigInt(m.id) > BigInt(maxId)) maxId = m.id;
        }

        if (isColdStart) {
          return new Response(JSON.stringify({ commands: [], lastId: maxId }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }

        const cmds = messages
          .filter(m => !m.author.bot && m.content && m.content.trim().startsWith("!"))
          .reverse()
          .map(m => ({ id: m.id, content: m.content.trim(), author: m.author.username }));

        return new Response(JSON.stringify({ commands: cmds, lastId: maxId }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }

      // ===== ПУШ СТАТУСА ДЛЯ ВЕБ-ПАНЕЛИ: тело вида {"status": {...}} =====
      if (bodyObj && Object.prototype.hasOwnProperty.call(bodyObj, "status")) {
        if (env.STATE) {
          await env.STATE.put("status", JSON.stringify(bodyObj.status));
        }
        return new Response("OK", { status: 200 });
      }

      // ===== ОБЫЧНОЕ УВЕДОМЛЕНИЕ: пересылка в discord webhook =====
      if (!env.DISCORD_WEBHOOK_URL) {
        return new Response("ОШИБКА: DISCORD_WEBHOOK_URL не задан", { status: 200 });
      }
      const resp = await fetch(env.DISCORD_WEBHOOK_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: bodyText,
      });
      const info = resp.ok ? "OK" : ("Discord error " + resp.status);
      return new Response(info, { status: 200 });

    } catch (e) {
      return new Response("Worker exception: " + e.message, { status: 200 });
    }
  },

  // ===== Cron Trigger: проверяет, не пропал ли крафтер =====
  async scheduled(event, env, ctx) {
    if (!env.STATE || !env.DISCORD_WEBHOOK_URL) return;

    const THRESHOLD_MS = 5 * 60 * 1000;
    const lastSeenStr = await env.STATE.get("lastSeen");
    const lastSeen = lastSeenStr ? parseInt(lastSeenStr, 10) : 0;
    const now = Date.now();
    const alerted = await env.STATE.get("alerted");

    if (lastSeen === 0) return;

    if (now - lastSeen > THRESHOLD_MS) {
      if (alerted !== "1") {
        const minutesAgo = Math.floor((now - lastSeen) / 60000);
        await fetch(env.DISCORD_WEBHOOK_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            content: "🆘 **Крафтер не отвечает** уже " + minutesAgo + " мин. Проверь компьютер в игре — возможно, он завис или перезагрузился."
          }),
        });
        await env.STATE.put("alerted", "1");
      }
    } else {
      if (alerted === "1") {
        await env.STATE.put("alerted", "0");
      }
    }
  }
}

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, c => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

async function renderDashboard(env) {
  let status = null;
  if (env.STATE) {
    const raw = await env.STATE.get("status");
    if (raw) {
      try { status = JSON.parse(raw); } catch (e) { /* ignore */ }
    }
  }

  const html = buildHtml(status);
  return new Response(html, {
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

function buildHtml(status) {
  const head = `<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>Автокрафт магазина</title>
<style>
  * { box-sizing: border-box; }
  body { background:#111; color:#eee; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
         padding:16px; max-width:720px; margin:0 auto; }
  h2 { color:#00aaff; margin-bottom:4px; }
  h3 { color:#00aaff; margin-top:22px; margin-bottom:6px; }
  .sub { color:#999; font-size:13px; margin-top:0; }
  table { width:100%; border-collapse:collapse; margin-top:6px; font-size:14px; }
  th { text-align:left; color:#999; font-weight:normal; border-bottom:1px solid #444; padding:6px 4px; }
  td { padding:6px 4px; border-bottom:1px solid #262626; }
  .badge { display:inline-block; padding:3px 10px; border-radius:5px; font-size:13px; margin-right:6px; margin-bottom:6px; }
  .ok { background:#1a4d1a; color:#55ff55; }
  .bad { background:#4d1a1a; color:#ff5555; }
  .warn { background:#4d3d1a; color:#ffaa00; }
  .num { text-align:right; }
</style>
</head>
<body>`;

  const foot = `</body></html>`;

  if (!status) {
    return head + `
  <h2>🏭 Автокрафт магазина</h2>
  <p class="sub">Ожидание первых данных от компьютера в игре...</p>
` + foot;
  }

  const itemsRows = (status.items || []).map(it => {
    const low = (it.stock || 0) < (it.keep || 0);
    return `<tr>
      <td>${esc(it.name)}</td>
      <td class="num" style="color:${low ? '#ff5555' : '#55ff55'}">${esc(it.stock)}</td>
      <td class="num" style="color:#999;">${esc(it.keep)}</td>
      <td class="num" style="color:#999;">${esc(it.craft)}</td>
      <td style="text-align:center;">${it.enabled ? '✅' : '🚫'}</td>
    </tr>`;
  }).join("");

  const jobsRows = (status.activeJobs || []).map(j => `<tr>
      <td>${esc(j.name)}</td>
      <td class="num">${esc(j.produced)}/${esc(j.amount)}</td>
      <td>${esc(j.status)}</td>
    </tr>`).join("");

  const jobsBlock = (status.activeJobs && status.activeJobs.length > 0) ? `
  <h3>Сейчас крафтится</h3>
  <table>
    <tr><th>Товар</th><th class="num">Прогресс</th><th>Статус</th></tr>
    ${jobsRows}
  </table>` : `<p class="sub" style="margin-top:16px;">Сейчас ничего не крафтится</p>`;

  return head + `
  <h2>🏭 Автокрафт магазина</h2>
  <p class="sub">Обновлено: ${esc(status.updatedAt)} (страница сама обновляется раз в 30 сек)</p>

  <div>
    <span class="badge ${status.paused ? 'warn' : 'ok'}">${status.paused ? 'ПАУЗА' : 'АВТО'}</span>
    <span class="badge ${status.meOk ? 'ok' : 'bad'}">ME: ${status.meOk ? 'OK' : 'НЕТ СВЯЗИ'}</span>
    <span class="badge ok">Активно: ${esc(status.activeCount)}/${esc(status.maxConcurrent)}</span>
  </div>

  <p style="margin-top:10px;">Скрафчено сегодня: <b>${esc(status.dailyCompleted || 0)}</b> &nbsp;|&nbsp;
     Провалено: <b>${esc(status.dailyFailed || 0)}</b></p>

  ${jobsBlock}

  <h3>Товары на складе</h3>
  <table>
    <tr><th>Товар</th><th class="num">Остаток</th><th class="num">Порог</th><th class="num">Крафт</th><th>Вкл</th></tr>
    ${itemsRows}
  </table>
` + foot;
}
