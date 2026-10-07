#!/usr/bin/env bash
# ============================================================
#  转蛋计分器 一键安装脚本（带 MySQL root 密码交互 / 支持管道执行）
#  适用：Ubuntu 20.04+ / Debian 11+（apt）  CentOS/RHEL 8+（dnf/yum）
#  用法：sudo bash zhuandanhuanjing.sh
#        sudo MYSQL_ROOT_PASS=root密码 bash zhuandanhuanjing.sh   # 跳过交互
#        sudo DOMAIN=your.domain.com bash zhuandanhuanjing.sh     # 同时配置 Nginx
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# 从终端读取（即使脚本通过管道执行）
TTY=/dev/tty
if [[ ! -e "$TTY" ]]; then TTY=/dev/stdin; fi

ask() { echo -e "${CYAN}[?]${NC} $*" > "$TTY"; }

# ---------------- 可配置项 ----------------
INSTALL_DIR="${INSTALL_DIR:-/var/www/zhuandan}"
DB_NAME="${DB_NAME:-zhuandan}"
DB_USER="${DB_USER:-zhuandan}"
DB_PASS="${DB_PASS:-$(openssl rand -hex 12 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 24)}"
NODE_PORT="${NODE_PORT:-3000}"
DOMAIN="${DOMAIN:-}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-}"

[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $0"

# ---------------- 1. 检测包管理器 ----------------
if command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf   >/dev/null 2>&1; then PKG=dnf
elif command -v yum   >/dev/null 2>&1; then PKG=yum
else die "不支持的发行版（未找到 apt / dnf / yum）"; fi
log "包管理器：$PKG"

# ---------------- 2. 安装 Node.js 20 ----------------
need_node=0
if ! command -v node >/dev/null 2>&1; then
  need_node=1
else
  major=$(node -v | sed 's/v//;s/\..*//')
  [[ "$major" -lt 18 ]] && need_node=1
fi

if [[ $need_node -eq 1 ]]; then
  log "安装 Node.js 20 ..."
  if [[ $PKG == apt ]]; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
  else
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    $PKG install -y nodejs
  fi
fi
log "Node.js $(node -v)  npm $(npm -v)"

# ---------------- 3. 检查 / 安装 MySQL ----------------
if ! command -v mysql >/dev/null 2>&1; then
  warn "未检测到 MySQL，尝试安装 ..."
  if [[ $PKG == apt ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-server
  else
    $PKG install -y mysql-server || $PKG install -y mariadb-server
  fi
fi
systemctl enable --now mysql 2>/dev/null \
  || systemctl enable --now mysqld 2>/dev/null \
  || systemctl enable --now mariadb 2>/dev/null \
  || warn "未能自动启动 MySQL 服务，请检查"
log "MySQL 服务就绪"

# ---------------- 4. 创建项目目录 ----------------
log "创建项目目录：$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ---------------- 5. 写入 package.json ----------------
cat > package.json << 'PKG_EOF'
{
  "name": "zhuandan-scoreboard",
  "version": "1.0.0",
  "private": true,
  "description": "转蛋计分器",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "mysql2": "^3.11.0"
  }
}
PKG_EOF

# ---------------- 6. 写入 server.js ----------------
cat > server.js << 'SERVER_EOF'
'use strict';
require('dotenv').config();
const express = require('express');
const mysql = require('mysql2/promise');

const app = express();
app.use(express.json());
app.use(express.static(__dirname));

const pool = mysql.createPool({
  host: process.env.DB_HOST || '127.0.0.1',
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  waitForConnections: true,
  connectionLimit: 10,
  charset: 'utf8mb4',
  dateStrings: true
});

const bad = (msg, code = 400) => Object.assign(new Error(msg), { status: code });

app.get('/api/rooms', async (req, res, next) => {
  try {
    const [rows] = await pool.query(`
      SELECT r.id, r.name, r.created_at,
        (SELECT COUNT(*) FROM players p WHERE p.room_id = r.id AND p.active = 1) AS player_count,
        (SELECT COUNT(*) FROM rounds  o WHERE o.room_id = r.id) AS round_count
      FROM rooms r
      ORDER BY r.created_at DESC, r.id DESC
    `);
    res.json(rows);
  } catch (e) { next(e); }
});

app.post('/api/rooms', async (req, res, next) => {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const name = String(req.body?.name ?? '').trim();
    if (!name) throw bad('缺少房间名称');
    const players = Array.isArray(req.body?.players) ? req.body.players : [];

    const [r] = await conn.query('INSERT INTO rooms (name) VALUES (?)', [name]);
    const roomId = r.insertId;

    for (const p of players) {
      const n = String(p ?? '').trim();
      if (n) await conn.query('INSERT INTO players (room_id, name) VALUES (?, ?)', [roomId, n]);
    }
    await conn.commit();
    res.json({ id: roomId });
  } catch (e) {
    await conn.rollback();
    next(e);
  } finally { conn.release(); }
});

app.get('/api/rooms/:id', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    const [[room]] = await pool.query('SELECT id, name, created_at FROM rooms WHERE id = ?', [id]);
    if (!room) throw bad('房间不存在', 404);

    const [players] = await pool.query(
      'SELECT id, room_id, name, score, active FROM players WHERE room_id = ? ORDER BY id', [id]);
    const [rounds] = await pool.query(
      'SELECT id, room_id, seq, point, w1, w2, l1, l2, created_at FROM rounds WHERE room_id = ? ORDER BY seq', [id]);

    res.json({ room, players, rounds });
  } catch (e) { next(e); }
});

app.post('/api/rooms/:id/players', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    const name = String(req.body?.name ?? '').trim();
    if (!name) throw bad('请输入牌友名字');

    const [[room]] = await pool.query('SELECT id FROM rooms WHERE id = ?', [id]);
    if (!room) throw bad('房间不存在', 404);

    await pool.query('INSERT INTO players (room_id, name) VALUES (?, ?)', [id, name]);
    res.json({ ok: true });
  } catch (e) { next(e); }
});

app.patch('/api/players/:id', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    const active = req.body?.active ? 1 : 0;
    const [r] = await pool.query('UPDATE players SET active = ? WHERE id = ?', [active, id]);
    if (!r.affectedRows) throw bad('牌友不存在', 404);
    res.json({ ok: true });
  } catch (e) { next(e); }
});

app.post('/api/rooms/:id/rounds', async (req, res, next) => {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const roomId = Number(req.params.id);
    const point = Number(req.body?.point);
    const winners = (req.body?.winners || []).map(Number);
    const losers  = (req.body?.losers  || []).map(Number);

    if (![1, 2, 3].includes(point)) throw bad('分值必须是 1 / 2 / 3');
    if (winners.length !== 2) throw bad('胜者必须是 2 人');
    if (losers.length  !== 2) throw bad('负者必须是 2 人');

    const all = [...winners, ...losers];
    if (new Set(all).size !== 4) throw bad('4 人不能重复');

    const ph = all.map(() => '?').join(',');
    const [rows] = await conn.query(
      `SELECT id FROM players WHERE room_id = ? AND active = 1 AND id IN (${ph})`,
      [roomId, ...all]
    );
    if (rows.length !== 4) throw bad('牌友不属于该房间或已退场');

    const [[m]] = await conn.query(
      'SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM rounds WHERE room_id = ?', [roomId]);
    const seq = m.next;

    await conn.query(
      'INSERT INTO rounds (room_id, seq, point, w1, w2, l1, l2) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [roomId, seq, point, winners[0], winners[1], losers[0], losers[1]]
    );

    const wph = winners.map(() => '?').join(',');
    const lph = losers.map(() => '?').join(',');
    await conn.query(`UPDATE players SET score = score + ? WHERE id IN (${wph})`, [point, ...winners]);
    await conn.query(`UPDATE players SET score = score - ? WHERE id IN (${lph})`, [point, ...losers]);

    await conn.commit();
    res.json({ ok: true, seq });
  } catch (e) {
    await conn.rollback();
    next(e);
  } finally { conn.release(); }
});

app.delete('/api/rooms/:id/rounds/last', async (req, res, next) => {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const roomId = Number(req.params.id);

    const [[last]] = await conn.query(
      'SELECT id, point, w1, w2, l1, l2 FROM rounds WHERE room_id = ? ORDER BY seq DESC LIMIT 1',
      [roomId]);
    if (!last) throw bad('没有可撤销的记录');

    await conn.query('DELETE FROM rounds WHERE id = ?', [last.id]);

    const winners = [last.w1, last.w2];
    const losers  = [last.l1, last.l2];
    const wph = winners.map(() => '?').join(',');
    const lph = losers.map(() => '?').join(',');

    await conn.query(`UPDATE players SET score = score - ? WHERE id IN (${wph})`, [last.point, ...winners]);
    await conn.query(`UPDATE players SET score = score + ? WHERE id IN (${lph})`, [last.point, ...losers]);

    await conn.commit();
    res.json({ ok: true });
  } catch (e) {
    await conn.rollback();
    next(e);
  } finally { conn.release(); }
});

app.use((err, req, res, _next) => {
  console.error('[ERROR]', err.message);
  res.status(err.status || 500).json({ error: err.message || '服务器内部错误' });
});

const PORT = Number(process.env.PORT || 3000);
app.listen(PORT, '0.0.0.0', () => {
  console.log(`转蛋计分器已启动：http://0.0.0.0:${PORT}`);
});
SERVER_EOF

# ---------------- 7. 写入 .env ----------------
cat > .env << ENV_EOF
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASS}
DB_NAME=${DB_NAME}
PORT=${NODE_PORT}
ENV_EOF
chmod 600 .env

# ---------------- 8. 写入 index.html ----------------
cat > index.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0b1220">
<title>转蛋计分器</title>
<style>
:root{
  --bg:#0b1220; --card:#151f33; --card2:#1b2740; --line:#26344f;
  --txt:#e8eefc; --sub:#8fa1c0;
  --green:#34d399; --red:#fb7185; --blue:#38bdf8;
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;padding:0}
body{
  background:var(--bg);color:var(--txt);padding-bottom:48px;
  font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
}
#app{max-width:720px;margin:0 auto;padding:16px}
h2{font-size:14px;margin:0;color:var(--sub);font-weight:700;letter-spacing:.6px}
header.top{display:flex;align-items:center;gap:10px;margin:4px 0 16px}
header.top h1{font-size:20px;margin:0;font-weight:700;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.back{color:var(--sub);text-decoration:none;font-size:22px;line-height:1;width:34px;height:34px;
  display:flex;align-items:center;justify-content:center;border:1px solid var(--line);border-radius:10px;flex:none}
.back:active{background:var(--card2)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;margin-bottom:14px}
.card .hd{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:12px}
.card .hd h2{margin:0}
.sub{color:var(--sub);font-size:12px}
.empty{color:var(--sub);font-size:14px;text-align:center;padding:10px 0;margin:0}
input{width:100%;background:var(--card2);border:1px solid var(--line);border-radius:10px;
  padding:12px 14px;color:var(--txt);font-size:16px;outline:none;margin-bottom:10px;font-family:inherit}
input:focus{border-color:var(--blue)}
input::placeholder{color:#5b6d8c}
button{font-family:inherit;font-size:15px;cursor:pointer;border:none;border-radius:10px}
.primary{width:100%;background:var(--blue);color:#04233a;font-weight:800;padding:14px;font-size:16px}
.primary:disabled{opacity:.3;cursor:not-allowed}
.primary.small{width:auto;padding:0 18px;font-size:15px;white-space:nowrap}
.ghost{background:transparent;border:1px solid var(--line);color:var(--sub);padding:6px 12px;font-size:13px}
.ghost:active{background:var(--card2)}
a.room{display:flex;align-items:center;gap:12px;text-decoration:none;color:inherit}
a.room:active{background:var(--card2)}
.room-main{flex:1;min-width:0}
.rname{font-size:16px;font-weight:700;margin-bottom:4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.arrow{color:var(--sub);font-size:22px;flex:none}
.rank-row{display:flex;align-items:center;gap:10px;padding:9px 0;border-bottom:1px dashed var(--line);font-size:15px}
.rank-row:last-child{border-bottom:none}
.rank-row.off{opacity:.42}
.rank-no{width:20px;color:var(--sub);font-size:12px;font-weight:700;flex:none;text-align:center}
.rank-name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.rank-score{font-weight:800;font-size:17px;font-variant-numeric:tabular-nums;min-width:52px;text-align:right}
.rank-score.pos{color:var(--green)}
.rank-score.neg{color:var(--red)}
.rank-score.zero{color:var(--sub)}
.tag-off{font-size:11px;color:var(--sub);border:1px solid var(--line);border-radius:6px;padding:1px 6px;flex:none}
.seg{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:14px}
.seg button{background:var(--card2);border:1px solid var(--line);color:var(--txt);padding:11px;font-weight:700;font-size:15px}
.seg button.on{background:var(--blue);color:#04233a;border-color:var(--blue)}
.pick-block{border:1px solid var(--line);border-radius:12px;padding:12px;margin-bottom:12px}
.pick-block.win{border-color:rgba(52,211,153,.45);background:rgba(52,211,153,.05)}
.pick-block.lose{border-color:rgba(251,113,133,.45);background:rgba(251,113,133,.05)}
.pick-hd{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:10px;gap:8px}
.pick-hd span{font-weight:700;font-size:14px}
.pick-block.win .pick-hd span{color:var(--green)}
.pick-block.lose .pick-hd span{color:var(--red)}
.pick-hd em{font-style:normal;font-size:12px;color:var(--sub);white-space:nowrap}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip{background:var(--card2);border:1px solid var(--line);color:var(--txt);padding:9px 15px;border-radius:999px;font-size:14px;transition:.12s}
.chip:active{transform:scale(.95)}
.chip.win.on{background:var(--green);color:#04301f;border-color:var(--green);font-weight:800}
.chip.lose.on{background:var(--red);color:#3a0410;border-color:var(--red);font-weight:800}
.chip.dim{opacity:.25}
.round{display:flex;gap:10px;padding:10px 0;border-bottom:1px dashed var(--line)}
.round:last-child{border-bottom:none}
.round .seq{color:var(--sub);font-size:12px;width:30px;flex:none;padding-top:3px}
.round .body{flex:1;min-width:0;display:flex;flex-direction:column;gap:5px}
.rline{display:flex;align-items:center;gap:8px;font-size:14px}
.rline .names{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tag{font-size:11px;padding:1px 6px;border-radius:6px;flex:none;font-weight:800}
.tag.win{background:rgba(52,211,153,.16);color:var(--green)}
.tag.lose{background:rgba(251,113,133,.16);color:var(--red)}
.pts{font-weight:800;font-size:13px;font-variant-numeric:tabular-nums;flex:none}
.pts.pos{color:var(--green)}
.pts.neg{color:var(--red)}
.rtime{color:var(--sub);font-size:11px;flex:none;padding-top:3px}
.addrow{display:flex;gap:8px;margin-bottom:12px}
.addrow input{margin-bottom:0;flex:1;min-width:0}
.prow{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px dashed var(--line);font-size:15px}
.prow:last-child{border-bottom:none}
.prow.off{opacity:.45}
.prow .pname{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
</style>
</head>
<body>
<div id="app"></div>
<script>
'use strict';
const $app = document.getElementById('app');
const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtTime = t => {
  const d = new Date(t); if (isNaN(d.getTime())) return '';
  const p = n => String(n).padStart(2,'0');
  return `${p(d.getMonth()+1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
};
async function api(url, opt = {}) {
  const res = await fetch(url, { headers: {'Content-Type':'application/json'}, ...opt });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || '请求失败');
  return data;
}
const state = {
  view: 'list', rooms: [], roomId: null, room: null,
  players: [], rounds: [], point: 1,
  winners: [], losers: [], manageOpen: true,
  draftName: '', draftRoomName: ''
};
function route() {
  const hash = location.hash.slice(1) || '/';
  const m = hash.match(/^\/r\/(\d+)$/);
  if (m) {
    const id = Number(m[1]);
    if (id !== state.roomId) {
      state.roomId = id; state.winners = []; state.losers = [];
      state.point = 1; state.draftName = '';
    }
    loadRoom(id);
  } else {
    state.roomId = null; loadList();
  }
}
window.addEventListener('hashchange', route);
window.addEventListener('DOMContentLoaded', route);
async function loadList() {
  state.view = 'list';
  try { state.rooms = await api('/api/rooms'); } catch (e) { state.rooms = []; }
  render();
}
async function loadRoom(id) {
  try {
    const data = await api('/api/rooms/' + id);
    state.view = 'room';
    state.room = data.room; state.players = data.players; state.rounds = data.rounds;
    const ids = new Set(data.players.map(p => p.id));
    state.winners = state.winners.filter(i => ids.has(i));
    state.losers  = state.losers.filter(i => ids.has(i));
    render();
  } catch (e) { alert(e.message); location.hash = '#/'; }
}
function render() {
  if (state.view === 'room' && state.room) renderRoom(); else renderList();
}
function renderList() {
  const rooms = state.rooms;
  $app.innerHTML = `
    <header class="top"><h1>转蛋计分器</h1></header>
    <section class="card">
      <h2 style="margin-bottom:12px">新建房间</h2>
      <input id="roomName" placeholder="房间名称，例如：周三转蛋局" maxlength="40" value="${esc(state.draftRoomName)}">
      <input id="initPlayers" placeholder="初始牌友，用逗号分隔，如：老王,小李,阿强,大刘" maxlength="120">
      <button class="primary" id="createRoom">创建房间</button>
    </section>
    <section>
      <h2 style="margin:0 0 12px 4px">房间（${rooms.length}）</h2>
      ${rooms.length ? rooms.map(r => `
        <a class="card room" href="#/r/${r.id}">
          <div class="room-main">
            <div class="rname">${esc(r.name)}</div>
            <div class="sub">${r.player_count} 人在场 · 已打 ${r.round_count} 局 · ${fmtTime(r.created_at)}</div>
          </div>
          <div class="arrow">›</div>
        </a>`).join('') : '<p class="empty">还没有房间，先建一个吧</p>'}
    </section>`;
  const roomNameEl = document.getElementById('roomName');
  const initEl = document.getElementById('initPlayers');
  const createBtn = document.getElementById('createRoom');
  roomNameEl.addEventListener('input', () => { state.draftRoomName = roomNameEl.value; });
  roomNameEl.addEventListener('keydown', e => { if (e.key === 'Enter') initEl.focus(); });
  initEl.addEventListener('keydown', e => { if (e.key === 'Enter') createBtn.click(); });
  createBtn.onclick = async () => {
    const name = roomNameEl.value.trim();
    if (!name) return alert('请输入房间名称');
    const players = initEl.value.split(/[,，、\s]+/).map(s => s.trim()).filter(Boolean);
    createBtn.disabled = true;
    try {
      const r = await api('/api/rooms', {
        method: 'POST', body: JSON.stringify({ name, players })
      });
      state.draftRoomName = '';
      location.hash = '#/r/' + r.id;
    } catch (e) { alert(e.message); createBtn.disabled = false; }
  };
}
function renderRoom() {
  const { room, players, rounds, point, winners, losers } = state;
  const active = players.filter(p => p.active);
  const nameOf = id => { const p = players.find(x => x.id === id); return p ? p.name : '已删除'; };
  const ready = winners.length === 2 && losers.length === 2;
  const canPlay = active.length >= 4;
  const rankRows = [...players].sort((a,b) => b.score - a.score || a.id - b.id).map((p,i) => {
    const cls = p.score > 0 ? 'pos' : p.score < 0 ? 'neg' : 'zero';
    const sign = p.score > 0 ? '+' : '';
    return `<div class="rank-row ${p.active ? '' : 'off'}">
      <span class="rank-no">${i+1}</span>
      <span class="rank-name">${esc(p.name)}</span>
      ${p.active ? '' : '<span class="tag-off">退场</span>'}
      <span class="rank-score ${cls}">${sign}${p.score}</span>
    </div>`;
  }).join('');
  const chip = (p, side) => {
    const on = side === 'win' ? winners.includes(p.id) : losers.includes(p.id);
    const other = side === 'win' ? losers.includes(p.id) : winners.includes(p.id);
    return `<button class="chip ${side}${on ? ' on' : ''}${other ? ' dim' : ''}"
      data-side="${side}" data-id="${p.id}">${esc(p.name)}</button>`;
  };
  const winChips  = active.map(p => chip(p,'win')).join('')  || '<span class="sub">暂无在场牌友</span>';
  const loseChips = active.map(p => chip(p,'lose')).join('') || '<span class="sub">暂无在场牌友</span>';
  const roundRows = rounds.slice().reverse().map(r => `
    <div class="round">
      <span class="seq">#${r.seq}</span>
      <div class="body">
        <div class="rline"><span class="tag win">胜</span>
          <span class="names">${esc(nameOf(r.w1))} · ${esc(nameOf(r.w2))}</span>
          <span class="pts pos">+${r.point}</span></div>
        <div class="rline"><span class="tag lose">负</span>
          <span class="names">${esc(nameOf(r.l1))} · ${esc(nameOf(r.l2))}</span>
          <span class="pts neg">−${r.point}</span></div>
      </div>
      <span class="rtime">${fmtTime(r.created_at)}</span>
    </div>`).join('');
  $app.innerHTML = `
    <header class="top">
      <a class="back" href="#/">‹</a>
      <h1>${esc(room.name)}</h1>
    </header>
    <section class="card">
      <div class="hd"><h2>积分榜</h2>
        <span class="sub">${active.length} 人在场 / 共 ${players.length} 人</span></div>
      ${rankRows || '<p class="empty">还没有牌友，先在下面添加</p>'}
    </section>
    <section class="card">
      <div class="hd"><h2>记录本局</h2>
        ${rounds.length ? '<button class="ghost" id="undoBtn">撤销上局</button>' : ''}</div>
      ${canPlay ? `
        <div class="seg" id="seg">
          ${[1,2,3].map(v => `<button data-p="${v}" class="${point === v ? 'on' : ''}">+${v} 分</button>`).join('')}
        </div>
        <div class="pick-block win">
          <div class="pick-hd"><span>胜者（${winners.length}/2）</span><em>各 +${point} 分</em></div>
          <div class="chips">${winChips}</div>
        </div>
        <div class="pick-block lose">
          <div class="pick-hd"><span>负者（${losers.length}/2）</span><em>各 −${point} 分</em></div>
          <div class="chips">${loseChips}</div>
        </div>
        <button class="primary" id="submitRound" ${ready ? '' : 'disabled'}>记录本局</button>
      ` : '<p class="empty">至少需要 4 位在场牌友才能开打</p>'}
    </section>
    <section class="card">
      <div class="hd"><h2>牌友管理</h2>
        <button class="ghost" id="toggleManage">${state.manageOpen ? '收起' : '展开'}</button></div>
      ${state.manageOpen ? `
        <div class="addrow">
          <input id="newPlayer" placeholder="输入牌友名字" maxlength="20" value="${esc(state.draftName)}">
          <button class="primary small" id="addPlayerBtn">加入</button>
        </div>
        <div class="plist">
          ${players.map(p => `
            <div class="prow ${p.active ? '' : 'off'}">
              <span class="pname">${esc(p.name)}</span>
              <span class="sub">${p.score > 0 ? '+' : ''}${p.score}</span>
              <button class="ghost" data-toggle="${p.id}" data-active="${p.active}">
                ${p.active ? '退场' : '归队'}
              </button>
            </div>`).join('') || '<p class="empty">还没有牌友</p>'}
        </div>` : ''}
    </section>
    <section class="card">
      <h2 style="margin-bottom:12px">对局记录（${rounds.length}）</h2>
      ${roundRows || '<p class="empty">还没有记录</p>'}
    </section>`;
  bindRoomEvents();
}
function bindRoomEvents() {
  const seg = document.getElementById('seg');
  if (seg) seg.querySelectorAll('button').forEach(b => {
    b.onclick = () => { state.point = Number(b.dataset.p); render(); };
  });
  document.querySelectorAll('.chip').forEach(c => {
    c.onclick = () => togglePick(c.dataset.side, Number(c.dataset.id));
  });
  const submit = document.getElementById('submitRound');
  if (submit) submit.onclick = doSubmitRound;
  const undo = document.getElementById('undoBtn');
  if (undo) undo.onclick = doUndo;
  const tm = document.getElementById('toggleManage');
  if (tm) tm.onclick = () => { state.manageOpen = !state.manageOpen; render(); };
  const np = document.getElementById('newPlayer');
  if (np) {
    np.addEventListener('input', () => { state.draftName = np.value; });
    np.addEventListener('keydown', e => {
      if (e.key === 'Enter') document.getElementById('addPlayerBtn').click();
    });
  }
  const addBtn = document.getElementById('addPlayerBtn');
  if (addBtn) addBtn.onclick = doAddPlayer;
  document.querySelectorAll('[data-toggle]').forEach(b => {
    b.onclick = async () => {
      b.disabled = true;
      try {
        await api('/api/players/' + b.dataset.toggle, {
          method: 'PATCH',
          body: JSON.stringify({ active: b.dataset.active !== '1' })
        });
        await loadRoom(state.roomId);
      } catch (e) { alert(e.message); b.disabled = false; }
    };
  });
}
function togglePick(side, id) {
  const W = state.winners, L = state.losers;
  if (side === 'win') {
    const i = W.indexOf(id);
    if (i >= 0) W.splice(i, 1);
    else {
      if (W.length >= 2) return;
      const j = L.indexOf(id); if (j >= 0) L.splice(j, 1);
      W.push(id);
    }
  } else {
    const i = L.indexOf(id);
    if (i >= 0) L.splice(i, 1);
    else {
      if (L.length >= 2) return;
      const j = W.indexOf(id); if (j >= 0) W.splice(j, 1);
      L.push(id);
    }
  }
  render();
}
async function doSubmitRound() {
  const btn = document.getElementById('submitRound');
  if (!btn) return; btn.disabled = true;
  try {
    await api(`/api/rooms/${state.roomId}/rounds`, {
      method: 'POST',
      body: JSON.stringify({ point: state.point, winners: state.winners, losers: state.losers })
    });
    state.winners = []; state.losers = [];
    await loadRoom(state.roomId);
  } catch (e) { alert(e.message); btn.disabled = false; }
}
async function doUndo() {
  if (!confirm('确定撤销最后一局吗？分数会回退。')) return;
  try {
    await api(`/api/rooms/${state.roomId}/rounds/last`, { method: 'DELETE' });
    await loadRoom(state.roomId);
  } catch (e) { alert(e.message); }
}
async function doAddPlayer() {
  const name = state.draftName.trim();
  if (!name) return alert('请输入牌友名字');
  const btn = document.getElementById('addPlayerBtn');
  btn.disabled = true;
  try {
    await api(`/api/rooms/${state.roomId}/players`, {
      method: 'POST', body: JSON.stringify({ name })
    });
    state.draftName = '';
    await loadRoom(state.roomId);
  } catch (e) { alert(e.message); btn.disabled = false; }
}
</script>
</body>
</html>
HTML_EOF

# ============================================================
#  9. 初始化数据库（交互式验证 root 密码 / 支持管道执行）
# ============================================================
echo
echo "================================================================"
echo "  准备初始化 MySQL 数据库"
echo "  将创建：数据库 ${DB_NAME}、用户 ${DB_USER}"
echo "================================================================"
echo

SQL_FILE=$(mktemp)
cat > "$SQL_FILE" <<SQL_EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
USE \`${DB_NAME}\`;

CREATE TABLE IF NOT EXISTS rooms (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  name       VARCHAR(100) NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS players (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  room_id    INT NOT NULL,
  name       VARCHAR(50) NOT NULL,
  score      INT NOT NULL DEFAULT 0,
  active     TINYINT(1) NOT NULL DEFAULT 1,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_room (room_id),
  CONSTRAINT fk_players_room FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS rounds (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  room_id    INT NOT NULL,
  seq        INT NOT NULL,
  point      INT NOT NULL,
  w1         INT NOT NULL,
  w2         INT NOT NULL,
  l1         INT NOT NULL,
  l2         INT NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_room_seq (room_id, seq),
  CONSTRAINT fk_rounds_room FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL_EOF

# --- 先尝试免密 ---
db_ok=0
if mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
  mysql -uroot < "$SQL_FILE" && db_ok=1
  [[ $db_ok -eq 1 ]] && log "数据库初始化完成（root 免密）"
elif sudo mysql -e "SELECT 1" >/dev/null 2>&1; then
  sudo mysql < "$SQL_FILE" && db_ok=1
  [[ $db_ok -eq 1 ]] && log "数据库初始化完成（sudo mysql）"
fi

# --- 环境变量指定密码 ---
if [[ $db_ok -eq 0 && -n "$MYSQL_ROOT_PASS" ]]; then
  if mysql -uroot -p"$MYSQL_ROOT_PASS" -e "SELECT 1" >/dev/null 2>&1; then
    mysql -uroot -p"$MYSQL_ROOT_PASS" < "$SQL_FILE" && db_ok=1
    [[ $db_ok -eq 1 ]] && log "数据库初始化完成（使用 MYSQL_ROOT_PASS 环境变量）"
  else
    warn "环境变量 MYSQL_ROOT_PASS 无法连接 MySQL，转为交互输入"
  fi
fi

# --- 交互式输入（从 /dev/tty 读取，兼容管道执行） ---
if [[ $db_ok -eq 0 ]]; then
  echo > "$TTY"
  echo -e "${YELLOW}[!]${NC} 自动登录 MySQL root 失败，需要你手动提供 root 密码" > "$TTY"
  echo > "$TTY"

  for attempt in 1 2 3; do
    printf "${CYAN}[?]${NC} 请输入 MySQL root 密码（第 %d/3 次，输入不回显）：" "$attempt" > "$TTY"
    ROOT_PW=""
    if ! IFS= read -r -s ROOT_PW < "$TTY"; then
      echo > "$TTY"
      warn "读取输入失败，请检查终端环境"
      break
    fi
    echo > "$TTY"

    if [[ -z "$ROOT_PW" ]]; then
      warn "未输入密码，重试"
      continue
    fi

    if mysql -uroot -p"$ROOT_PW" -e "SELECT 1" >/dev/null 2>&1; then
      log "密码验证成功，正在初始化数据库 ..."
      if mysql -uroot -p"$ROOT_PW" < "$SQL_FILE"; then
        db_ok=1
        MYSQL_ROOT_PASS="$ROOT_PW"
        break
      else
        warn "SQL 执行失败，请检查上方错误信息"
      fi
    else
      warn "密码错误，请重试"
    fi
  done
fi

if [[ $db_ok -eq 0 ]]; then
  warn "自动初始化失败，SQL 文件保留在：$SQL_FILE"
  warn "你可以稍后手动执行：mysql -uroot -p < $SQL_FILE"
  die "数据库初始化失败，请检查 MySQL root 账号密码后重新运行脚本"
fi
rm -f "$SQL_FILE"

# ---------------- 10. 安装依赖 ----------------
log "安装 npm 依赖 ..."
npm install --omit=dev --no-audit --no-fund --loglevel=error

# ---------------- 11. PM2 守护 ----------------
if ! command -v pm2 >/dev/null 2>&1; then
  log "安装 PM2 ..."
  npm install -g pm2 --loglevel=error
fi

pm2 delete zhuandan >/dev/null 2>&1 || true
pm2 start server.js --name zhuandan --cwd "$INSTALL_DIR" >/dev/null
pm2 save >/dev/null

log "配置 PM2 开机自启 ..."
pm2 startup systemd -u root --hp /root 2>&1 | tail -n 1 | bash >/dev/null 2>&1 \
  || warn "PM2 开机自启未配置成功，可手动执行：pm2 startup"

# ---------------- 12. 可选：Nginx ----------------
if [[ -n "$DOMAIN" ]]; then
  if ! command -v nginx >/dev/null 2>&1; then
    log "安装 Nginx ..."
    if [[ $PKG == apt ]]; then apt-get install -y -qq nginx; else $PKG install -y nginx; fi
  fi

  CONF_DIR="/etc/nginx/conf.d"
  [[ -d /etc/nginx/conf.d ]] || CONF_DIR="/etc/nginx/sites-enabled"
  mkdir -p "$CONF_DIR"

  cat > "${CONF_DIR}/zhuandan.conf" <<NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 2m;

    location / {
        proxy_pass http://127.0.0.1:${NODE_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_EOF

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    log "Nginx 已配置：http://${DOMAIN}"
  else
    warn "Nginx 配置校验失败，请手动检查 ${CONF_DIR}/zhuandan.conf"
  fi
fi

# ---------------- 13. 结束 ----------------
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo "================================================================"
echo -e "  ${GREEN}转蛋计分器 安装完成！${NC}"
echo "================================================================"
echo "  访问地址 ： http://${DOMAIN:-${IP:-服务器IP}}:${NODE_PORT}"
[[ -n "$DOMAIN" ]] && echo "  也可通过 ： http://${DOMAIN}"
echo "  安装目录 ： ${INSTALL_DIR}"
echo "  数据库名 ： ${DB_NAME}"
echo "  数据库用户： ${DB_USER}"
echo "  数据库密码： ${DB_PASS}"
echo
echo "  常用命令："
echo "    pm2 status                 # 查看状态"
echo "    pm2 logs zhuandan          # 查看日志"
echo "    pm2 restart zhuandan       # 重启"
echo "    pm2 stop zhuandan          # 停止"
echo
echo "  修改配置：编辑 ${INSTALL_DIR}/.env 后 pm2 restart zhuandan"
echo "================================================================"
echo
warn "请务必保存好上面的数据库密码！"