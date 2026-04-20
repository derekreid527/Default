'use strict';

const STORAGE_KEY = 'tradeTracker_v1';
let trades = JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]');
let deleteTargetId = null;
let currentAsset = 'stock'; // 'stock' | 'option'

// ── DOM refs ──────────────────────────────────────────────────────────────────
const tradeForm   = document.getElementById('tradeForm');
const formTitle   = document.getElementById('formTitle');
const submitBtn   = document.getElementById('submitBtn');
const cancelBtn   = document.getElementById('cancelBtn');
const editIdInput = document.getElementById('editId');
const tickerInput = document.getElementById('ticker');
const actionInput = document.getElementById('action');
const sharesInput = document.getElementById('shares');
const priceInput  = document.getElementById('price');
const dateInput   = document.getElementById('tradeDate');
const notesInput  = document.getElementById('notes');
const sharesLabel = document.getElementById('sharesLabel');
const priceLabel  = document.getElementById('priceLabel');

const assetBtns   = document.querySelectorAll('.asset-btn');
const optionFields = document.getElementById('optionFields');
const strikeInput = document.getElementById('strike');
const expiryInput = document.getElementById('expiry');

const tabBtns          = document.querySelectorAll('.tab');
const portfolioSection = document.getElementById('tab-portfolio');
const historySection   = document.getElementById('tab-history');
const portfolioList    = document.getElementById('portfolioList');
const portfolioEmpty   = document.getElementById('portfolioEmpty');
const historyList      = document.getElementById('historyList');
const historyEmpty     = document.getElementById('historyEmpty');

const filterTicker = document.getElementById('filterTicker');
const filterAction = document.getElementById('filterAction');
const sortBy       = document.getElementById('sortBy');
const exportCsvBtn = document.getElementById('exportCsvBtn');

const openPositionsEl = document.getElementById('openPositions');
const costBasisEl     = document.getElementById('costBasis');
const realizedPnLEl   = document.getElementById('realizedPnL');
const totalTradesEl   = document.getElementById('totalTrades');

const modal         = document.getElementById('modal');
const confirmDelete = document.getElementById('confirmDelete');
const cancelDelete  = document.getElementById('cancelDelete');

// ── Helpers ───────────────────────────────────────────────────────────────────
function uid() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2);
}

function todayStr() {
  return new Date().toISOString().slice(0, 10);
}

function save() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(trades));
}

function fmt(n) {
  return '$' + Math.abs(Number(n)).toFixed(2);
}

function fmtPnL(n) {
  return (n >= 0 ? '+$' : '-$') + Math.abs(n).toFixed(2);
}

function fmtShares(n) {
  return Number(n).toFixed(4).replace(/\.?0+$/, '');
}

function fmtDate(s) {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, {
    month: 'short', day: 'numeric', year: 'numeric',
  });
}

function fmtExpiry(s) {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, {
    month: 'numeric', day: 'numeric', year: '2-digit',
  });
}

function escHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Returns unique key for grouping into a position
function posKey(trade) {
  if (trade.assetType === 'option') {
    return `${trade.ticker}|${trade.optionType}|${trade.strike}|${trade.expiry}`;
  }
  return trade.ticker;
}

// Options: total value = price (per share) × contracts × 100
function tradeTotal(trade) {
  if (trade.assetType === 'option') return trade.price * trade.shares * 100;
  return trade.price * trade.shares;
}

// ── Portfolio Computation (average-cost method) ───────────────────────────────
function computePortfolio() {
  const sorted = [...trades].sort((a, b) => {
    const dc = a.date.localeCompare(b.date);
    return dc !== 0 ? dc : a.id.localeCompare(b.id);
  });

  const positions = {};  // posKey → { shares/contracts, totalCost, meta }
  const tradePnL  = {};  // id → number | null
  let totalRealizedPnL = 0;

  for (const t of sorted) {
    const key = posKey(t);
    if (!positions[key]) {
      positions[key] = {
        shares: 0, totalCost: 0,
        ticker: t.ticker, assetType: t.assetType || 'stock',
        optionType: t.optionType, strike: t.strike, expiry: t.expiry,
      };
    }
    const pos = positions[key];
    const total = tradeTotal(t);

    if (t.action === 'buy') {
      pos.shares    += t.shares;
      pos.totalCost += total;
    } else {
      if (pos.shares > 0) {
        const avgCostPerUnit = pos.totalCost / pos.shares;
        const sellUnits  = Math.min(t.shares, pos.shares);
        // P&L uses actual trade quantity so oversells are reflected accurately
        const pnl = t.assetType === 'option'
          ? (t.price - avgCostPerUnit / 100) * t.shares * 100
          : (t.price - avgCostPerUnit) * t.shares;
        tradePnL[t.id] = pnl;
        totalRealizedPnL += pnl;
        pos.totalCost  = Math.max(0, pos.totalCost - avgCostPerUnit * sellUnits);
        pos.shares     = Math.max(0, pos.shares - sellUnits);
      } else {
        tradePnL[t.id] = null;
      }
    }
  }

  const openPositions = Object.entries(positions)
    .filter(([, p]) => p.shares >= 0.0001)
    .map(([, p]) => ({
      ...p,
      avgCost: p.totalCost / p.shares,
    }))
    .sort((a, b) => a.ticker.localeCompare(b.ticker));

  return { openPositions, tradePnL, totalRealizedPnL };
}

// ── Summary Cards ─────────────────────────────────────────────────────────────
function updateSummary(openPositions, totalRealizedPnL) {
  openPositionsEl.textContent = openPositions.length;
  costBasisEl.textContent     = fmt(openPositions.reduce((s, p) => s + p.totalCost, 0));
  totalTradesEl.textContent   = trades.length;
  realizedPnLEl.textContent   = fmtPnL(totalRealizedPnL);
  realizedPnLEl.className     = 'card__value ' + (totalRealizedPnL >= 0 ? 'positive' : 'negative');
}

// ── Portfolio Tab ─────────────────────────────────────────────────────────────
function renderPortfolio(openPositions) {
  portfolioList.innerHTML = '';
  if (openPositions.length === 0) {
    portfolioEmpty.classList.remove('hidden');
    return;
  }
  portfolioEmpty.classList.add('hidden');

  openPositions.forEach(pos => {
    const isOption  = pos.assetType === 'option';
    const qtyLabel  = isOption ? 'Contracts' : 'Shares';
    const costLabel = isOption ? 'Avg Premium' : 'Avg Cost';
    // For options: avgCost stored as (total cost / contracts), display per-share premium
    const avgDisplay = isOption ? fmt(pos.avgCost / 100) + '/sh' : fmt(pos.avgCost);

    let optionBadge = '';
    let optionDesc  = '';
    if (isOption) {
      const cls = pos.optionType === 'call' ? 'call' : 'put';
      optionBadge = `<span class="badge badge--${cls}">${pos.optionType}</span>`;
      optionDesc  = `<span class="option-desc">$${pos.strike} strike · exp ${fmtExpiry(pos.expiry)}</span>`;
    }

    const el = document.createElement('div');
    el.className = 'position-item';
    el.innerHTML = `
      <div class="position-ticker">
        ${escHtml(pos.ticker)}
        ${optionBadge}
      </div>
      <div class="position-details">
        ${optionDesc ? `<div class="position-detail" style="flex-basis:100%">${optionDesc}</div>` : ''}
        <div class="position-detail">
          <span class="detail-label">${qtyLabel}</span>
          <span class="detail-value">${fmtShares(pos.shares)}</span>
        </div>
        <div class="position-detail">
          <span class="detail-label">${costLabel}</span>
          <span class="detail-value">${avgDisplay}</span>
        </div>
        <div class="position-detail">
          <span class="detail-label">Cost Basis</span>
          <span class="detail-value">${fmt(pos.totalCost)}</span>
        </div>
      </div>
    `;
    portfolioList.appendChild(el);
  });
}

// ── History Tab ───────────────────────────────────────────────────────────────
function getFilteredHistory() {
  const tickerFilter = filterTicker.value.trim().toUpperCase();
  const actionFilter = filterAction.value;
  const sort         = sortBy.value;

  let list = trades.filter(t => {
    if (tickerFilter && !t.ticker.startsWith(tickerFilter)) return false;
    if (actionFilter !== 'all' && t.action !== actionFilter) return false;
    return true;
  });

  list.sort((a, b) => {
    if (sort === 'date-desc')  return b.date.localeCompare(a.date) || b.id.localeCompare(a.id);
    if (sort === 'date-asc')   return a.date.localeCompare(b.date) || a.id.localeCompare(b.id);
    if (sort === 'ticker')     return a.ticker.localeCompare(b.ticker);
    if (sort === 'value-desc') return tradeTotal(b) - tradeTotal(a);
    return 0;
  });

  return list;
}

function renderHistory(tradePnL) {
  const list = getFilteredHistory();
  historyList.innerHTML = '';

  if (list.length === 0) {
    historyEmpty.classList.remove('hidden');
    return;
  }
  historyEmpty.classList.add('hidden');

  list.forEach(t => {
    const isOption = t.assetType === 'option';
    const total    = tradeTotal(t);
    const pnl      = tradePnL[t.id];
    const qtyLabel = isOption ? 'Contracts' : 'Shares';
    const priceStr = isOption ? `${fmt(t.price)}/sh` : fmt(t.price);

    let optionInfo = '';
    if (isOption) {
      const cls = t.optionType === 'call' ? 'call' : 'put';
      optionInfo = `
        <span class="badge badge--${cls}">${t.optionType}</span>
        <div class="trade-meta-item">
          <span class="meta-label">Strike</span>
          <span class="meta-value">$${t.strike}</span>
        </div>
        <div class="trade-meta-item">
          <span class="meta-label">Expiry</span>
          <span class="meta-value">${fmtExpiry(t.expiry)}</span>
        </div>`;
    }

    let pnlHtml = '';
    if (t.action === 'sell' && pnl != null) {
      const cls = pnl >= 0 ? 'positive' : 'negative';
      pnlHtml = `
        <div class="trade-meta-item">
          <span class="meta-label">P&amp;L</span>
          <span class="pnl-badge ${cls}">${fmtPnL(pnl)}</span>
        </div>`;
    }

    const el = document.createElement('div');
    el.className = `trade-item is-${t.action}`;
    el.innerHTML = `
      <div class="trade-date">${fmtDate(t.date)}</div>
      <div class="trade-ticker">${escHtml(t.ticker)}</div>
      <span class="badge badge--${t.action}">${t.action}</span>
      ${optionInfo}
      <div class="trade-meta">
        <div class="trade-meta-item">
          <span class="meta-label">${qtyLabel}</span>
          <span class="meta-value">${fmtShares(t.shares)}</span>
        </div>
        <div class="trade-meta-item">
          <span class="meta-label">Price</span>
          <span class="meta-value">${priceStr}</span>
        </div>
        <div class="trade-meta-item">
          <span class="meta-label">Total</span>
          <span class="meta-value">${fmt(total)}</span>
        </div>
        ${pnlHtml}
        ${t.notes ? `<div class="trade-notes">"${escHtml(t.notes)}"</div>` : ''}
      </div>
      <div class="trade-actions">
        <button class="btn--secondary btn--icon" data-edit="${t.id}">Edit</button>
        <button class="btn--danger btn--icon" data-delete="${t.id}">Delete</button>
      </div>
    `;
    historyList.appendChild(el);
  });
}

// ── Main Render ───────────────────────────────────────────────────────────────
function render() {
  const { openPositions, tradePnL, totalRealizedPnL } = computePortfolio();
  updateSummary(openPositions, totalRealizedPnL);
  renderPortfolio(openPositions);
  renderHistory(tradePnL);
}

// ── Asset Type Toggle ─────────────────────────────────────────────────────────
function setAssetType(type) {
  currentAsset = type;
  assetBtns.forEach(b => b.classList.toggle('active', b.dataset.asset === type));
  optionFields.classList.toggle('hidden', type !== 'option');
  strikeInput.required = type === 'option';
  expiryInput.required = type === 'option';
  sharesLabel.textContent = type === 'option' ? 'Contracts' : 'Shares';
  priceLabel.textContent  = type === 'option' ? 'Premium / Share ($)' : 'Price per Share ($)';
  sharesInput.step        = type === 'option' ? '1' : '0.0001';
}

assetBtns.forEach(btn => {
  btn.addEventListener('click', () => setAssetType(btn.dataset.asset));
});

// ── Form ──────────────────────────────────────────────────────────────────────
dateInput.value = todayStr();

function resetForm() {
  tradeForm.reset();
  editIdInput.value = '';
  dateInput.value   = todayStr();
  formTitle.textContent = 'Log Trade';
  submitBtn.textContent = 'Log Trade';
  cancelBtn.classList.add('hidden');
  setAssetType('stock');
}

tickerInput.addEventListener('input', () => {
  tickerInput.value = tickerInput.value.toUpperCase();
});

tradeForm.addEventListener('submit', e => {
  e.preventDefault();
  const id = editIdInput.value;

  const isOption = currentAsset === 'option';
  const data = {
    ticker:    tickerInput.value.trim().toUpperCase(),
    action:    actionInput.value,
    shares:    parseFloat(sharesInput.value),
    price:     parseFloat(priceInput.value),
    date:      dateInput.value,
    notes:     notesInput.value.trim(),
    assetType: currentAsset,
  };

  if (isOption) {
    data.optionType = document.querySelector('input[name="optionType"]:checked').value;
    data.strike     = parseFloat(strikeInput.value);
    data.expiry     = expiryInput.value;
    if (!data.strike || !data.expiry) return;
  }

  if (!data.ticker || !(data.shares > 0) || !(data.price > 0) || !data.date) return;

  if (id) {
    const idx = trades.findIndex(t => t.id === id);
    if (idx !== -1) trades[idx] = { ...trades[idx], ...data };
  } else {
    trades.push({ id: uid(), ...data });
  }

  save();
  resetForm();
  render();
});

cancelBtn.addEventListener('click', resetForm);

// ── Tab Switching ─────────────────────────────────────────────────────────────
tabBtns.forEach(btn => {
  btn.addEventListener('click', () => {
    const tab = btn.dataset.tab;
    tabBtns.forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
    portfolioSection.classList.toggle('hidden', tab !== 'portfolio');
    historySection.classList.toggle('hidden', tab !== 'history');
  });
});

// ── History Event Delegation ──────────────────────────────────────────────────
historyList.addEventListener('click', e => {
  const editId   = e.target.dataset.edit;
  const deleteId = e.target.dataset.delete;

  if (editId) {
    const t = trades.find(tr => tr.id === editId);
    if (!t) return;
    const asset = t.assetType || 'stock';
    setAssetType(asset);
    editIdInput.value     = t.id;
    tickerInput.value     = t.ticker;
    actionInput.value     = t.action;
    sharesInput.value     = t.shares;
    priceInput.value      = t.price;
    dateInput.value       = t.date;
    notesInput.value      = t.notes || '';
    if (asset === 'option') {
      document.querySelector(`input[name="optionType"][value="${t.optionType}"]`).checked = true;
      strikeInput.value = t.strike;
      expiryInput.value = t.expiry;
    }
    formTitle.textContent = 'Edit Trade';
    submitBtn.textContent = 'Save Changes';
    cancelBtn.classList.remove('hidden');
    tradeForm.scrollIntoView({ behavior: 'smooth', block: 'start' });
    tabBtns.forEach(b => b.classList.toggle('active', b.dataset.tab === 'history'));
  }

  if (deleteId) {
    deleteTargetId = deleteId;
    modal.classList.remove('hidden');
  }
});

// ── Delete Modal ──────────────────────────────────────────────────────────────
confirmDelete.addEventListener('click', () => {
  trades = trades.filter(t => t.id !== deleteTargetId);
  deleteTargetId = null;
  modal.classList.add('hidden');
  save();
  render();
});

cancelDelete.addEventListener('click', () => {
  deleteTargetId = null;
  modal.classList.add('hidden');
});

modal.addEventListener('click', e => {
  if (e.target === modal) {
    deleteTargetId = null;
    modal.classList.add('hidden');
  }
});

// ── Filters ───────────────────────────────────────────────────────────────────
filterTicker.addEventListener('input', () => {
  filterTicker.value = filterTicker.value.toUpperCase();
  render();
});
filterAction.addEventListener('change', render);
sortBy.addEventListener('change', render);

// ── Export CSV ────────────────────────────────────────────────────────────────
exportCsvBtn.addEventListener('click', () => {
  const { tradePnL } = computePortfolio();
  const rows = [['Date', 'Ticker', 'Asset', 'Action', 'Qty', 'Price', 'Total', 'P&L', 'Type', 'Strike', 'Expiry', 'Notes']];

  [...trades]
    .sort((a, b) => b.date.localeCompare(a.date))
    .forEach(t => {
      const pnl = tradePnL[t.id];
      rows.push([
        t.date, t.ticker, t.assetType || 'stock', t.action,
        fmtShares(t.shares), t.price.toFixed(2),
        tradeTotal(t).toFixed(2),
        pnl != null ? pnl.toFixed(2) : '',
        t.optionType || '', t.strike || '', t.expiry || '',
        t.notes || '',
      ]);
    });

  const csv  = rows.map(r => r.map(v => `"${String(v).replace(/"/g, '""')}"`).join(',')).join('\n');
  const blob = new Blob([csv], { type: 'text/csv' });
  const url  = URL.createObjectURL(blob);
  const a    = Object.assign(document.createElement('a'), { href: url, download: `trades_${todayStr()}.csv` });
  a.click();
  URL.revokeObjectURL(url);
});

// ── Seed demo data ────────────────────────────────────────────────────────────
if (trades.length === 0) {
  const d = n => {
    const dt = new Date();
    dt.setDate(dt.getDate() + n);
    return dt.toISOString().slice(0, 10);
  };
  trades = [
    { id: uid(), assetType: 'stock',  ticker: 'AAPL', action: 'buy',  shares: 10, price: 175.50, date: d(-35), notes: 'Earnings play' },
    { id: uid(), assetType: 'stock',  ticker: 'TSLA', action: 'buy',  shares: 5,  price: 248.00, date: d(-28), notes: '' },
    { id: uid(), assetType: 'stock',  ticker: 'AAPL', action: 'buy',  shares: 5,  price: 179.20, date: d(-21), notes: 'Adding to position' },
    { id: uid(), assetType: 'option', ticker: 'NVDA', action: 'buy',  shares: 2,  price: 8.50,   date: d(-18), notes: 'Earnings call',
      optionType: 'call', strike: 500, expiry: d(30) },
    { id: uid(), assetType: 'stock',  ticker: 'NVDA', action: 'buy',  shares: 3,  price: 452.50, date: d(-14), notes: 'AI momentum' },
    { id: uid(), assetType: 'stock',  ticker: 'TSLA', action: 'sell', shares: 5,  price: 235.00, date: d(-10), notes: 'Stop loss' },
    { id: uid(), assetType: 'option', ticker: 'NVDA', action: 'sell', shares: 2,  price: 14.20,  date: d(-5),  notes: 'Closed for profit',
      optionType: 'call', strike: 500, expiry: d(30) },
    { id: uid(), assetType: 'stock',  ticker: 'AAPL', action: 'sell', shares: 8,  price: 186.75, date: d(-5),  notes: 'Partial profit' },
  ];
  save();
}

render();
