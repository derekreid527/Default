'use strict';

const STORAGE_KEY = 'billTracker_bills';

let bills = JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]');
let deleteTargetId = null;

// ── DOM refs ──────────────────────────────────────────────────────────────────
const billForm      = document.getElementById('billForm');
const formTitle     = document.getElementById('formTitle');
const submitBtn     = document.getElementById('submitBtn');
const cancelBtn     = document.getElementById('cancelBtn');
const editIdInput   = document.getElementById('editId');
const billName      = document.getElementById('billName');
const billAmount    = document.getElementById('billAmount');
const billDue       = document.getElementById('billDue');
const billCategory  = document.getElementById('billCategory');
const billNotes     = document.getElementById('billNotes');

const filterStatus   = document.getElementById('filterStatus');
const filterCategory = document.getElementById('filterCategory');
const sortBy         = document.getElementById('sortBy');

const billsList  = document.getElementById('billsList');
const emptyState = document.getElementById('emptyState');

const modal         = document.getElementById('modal');
const confirmDelete = document.getElementById('confirmDelete');
const cancelDelete  = document.getElementById('cancelDelete');

const totalDueEl    = document.getElementById('totalDue');
const totalPaidEl   = document.getElementById('totalPaid');
const totalUnpaidEl = document.getElementById('totalUnpaid');
const overdueEl     = document.getElementById('overdueCount');

// ── Helpers ───────────────────────────────────────────────────────────────────
function today() {
  return new Date().toISOString().slice(0, 10);
}

function isOverdue(bill) {
  return !bill.paid && bill.dueDate < today();
}

function fmt(amount) {
  return '$' + Number(amount).toFixed(2);
}

function fmtDate(dateStr) {
  // Parse as local date to avoid UTC offset shifting the day
  const [y, m, d] = dateStr.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, {
    month: 'short', day: 'numeric', year: 'numeric'
  });
}

function uid() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2);
}

function save() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(bills));
}

// ── Summary ───────────────────────────────────────────────────────────────────
function updateSummary() {
  const total    = bills.reduce((s, b) => s + Number(b.amount), 0);
  const paid     = bills.filter(b => b.paid).reduce((s, b) => s + Number(b.amount), 0);
  const unpaid   = bills.filter(b => !b.paid).reduce((s, b) => s + Number(b.amount), 0);
  const overdue  = bills.filter(isOverdue).length;

  totalDueEl.textContent    = fmt(total);
  totalPaidEl.textContent   = fmt(paid);
  totalUnpaidEl.textContent = fmt(unpaid);
  overdueEl.textContent     = overdue;
}

// ── Render ────────────────────────────────────────────────────────────────────
function getFiltered() {
  const status   = filterStatus.value;
  const category = filterCategory.value;
  const sort     = sortBy.value;

  let list = bills.filter(b => {
    if (category !== 'all' && b.category !== category) return false;
    if (status === 'paid')    return b.paid;
    if (status === 'unpaid')  return !b.paid && !isOverdue(b);
    if (status === 'overdue') return isOverdue(b);
    return true;
  });

  list.sort((a, b) => {
    if (sort === 'dueDate') return a.dueDate.localeCompare(b.dueDate);
    if (sort === 'amount')  return Number(b.amount) - Number(a.amount);
    if (sort === 'name')    return a.name.localeCompare(b.name);
    return 0;
  });

  return list;
}

function render() {
  updateSummary();
  const list = getFiltered();
  billsList.innerHTML = '';

  if (list.length === 0) {
    emptyState.classList.remove('hidden');
    return;
  }
  emptyState.classList.add('hidden');

  list.forEach(bill => {
    const overdue = isOverdue(bill);
    const statusClass = bill.paid ? 'paid' : overdue ? 'overdue' : 'unpaid';
    const badgeClass  = bill.paid ? 'badge--paid' : overdue ? 'badge--overdue' : 'badge--unpaid';
    const badgeText   = bill.paid ? 'Paid' : overdue ? 'Overdue' : 'Unpaid';

    const item = document.createElement('div');
    item.className = `bill-item ${statusClass}`;
    item.innerHTML = `
      <input type="checkbox" class="bill-checkbox" aria-label="Mark paid"
             ${bill.paid ? 'checked' : ''} data-id="${bill.id}" />
      <div class="bill-info">
        <div class="bill-name">${escHtml(bill.name)}</div>
        <div class="bill-meta">
          <span>Due: ${fmtDate(bill.dueDate)}</span>
          <span>${escHtml(bill.category)}</span>
          ${bill.notes ? `<span>${escHtml(bill.notes)}</span>` : ''}
          <span class="badge ${badgeClass}">${badgeText}</span>
        </div>
      </div>
      <div class="bill-amount">${fmt(bill.amount)}</div>
      <div class="bill-actions">
        <button class="btn--secondary btn--icon" data-edit="${bill.id}">Edit</button>
        <button class="btn--danger btn--icon" data-delete="${bill.id}">Delete</button>
      </div>
    `;
    billsList.appendChild(item);
  });
}

function escHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ── Form ──────────────────────────────────────────────────────────────────────
function resetForm() {
  billForm.reset();
  editIdInput.value = '';
  formTitle.textContent = 'Add Bill';
  submitBtn.textContent = 'Add Bill';
  cancelBtn.classList.add('hidden');
}

billForm.addEventListener('submit', e => {
  e.preventDefault();
  const id = editIdInput.value;

  const data = {
    name:     billName.value.trim(),
    amount:   parseFloat(billAmount.value),
    dueDate:  billDue.value,
    category: billCategory.value,
    notes:    billNotes.value.trim(),
  };

  if (id) {
    const idx = bills.findIndex(b => b.id === id);
    if (idx !== -1) bills[idx] = { ...bills[idx], ...data };
  } else {
    bills.push({ id: uid(), paid: false, ...data });
  }

  save();
  resetForm();
  render();
});

cancelBtn.addEventListener('click', resetForm);

// ── List events (delegation) ──────────────────────────────────────────────────
billsList.addEventListener('change', e => {
  if (e.target.matches('.bill-checkbox')) {
    const id  = e.target.dataset.id;
    const bill = bills.find(b => b.id === id);
    if (bill) { bill.paid = e.target.checked; save(); render(); }
  }
});

billsList.addEventListener('click', e => {
  const editId   = e.target.dataset.edit;
  const deleteId = e.target.dataset.delete;

  if (editId) {
    const bill = bills.find(b => b.id === editId);
    if (!bill) return;
    editIdInput.value    = bill.id;
    billName.value       = bill.name;
    billAmount.value     = bill.amount;
    billDue.value        = bill.dueDate;
    billCategory.value   = bill.category;
    billNotes.value      = bill.notes || '';
    formTitle.textContent = 'Edit Bill';
    submitBtn.textContent = 'Save Changes';
    cancelBtn.classList.remove('hidden');
    billForm.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  if (deleteId) {
    deleteTargetId = deleteId;
    modal.classList.remove('hidden');
  }
});

// ── Delete modal ──────────────────────────────────────────────────────────────
confirmDelete.addEventListener('click', () => {
  bills = bills.filter(b => b.id !== deleteTargetId);
  deleteTargetId = null;
  save();
  modal.classList.add('hidden');
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
[filterStatus, filterCategory, sortBy].forEach(el =>
  el.addEventListener('change', render)
);

// ── Seed demo data if empty ───────────────────────────────────────────────────
if (bills.length === 0) {
  const t = today();
  const addDays = (d, n) => {
    const dt = new Date(d); dt.setDate(dt.getDate() + n); return dt.toISOString().slice(0, 10);
  };
  bills = [
    { id: uid(), name: 'Electricity',    amount: 112.50, dueDate: addDays(t, 5),   category: 'Utilities',       notes: '',             paid: false },
    { id: uid(), name: 'Internet',       amount: 59.99,  dueDate: addDays(t, -3),  category: 'Utilities',       notes: 'Fiber plan',   paid: false },
    { id: uid(), name: 'Rent',           amount: 1450.00,dueDate: addDays(t, 12),  category: 'Rent / Mortgage', notes: '',             paid: false },
    { id: uid(), name: 'Netflix',        amount: 15.49,  dueDate: addDays(t, 2),   category: 'Subscription',    notes: '',             paid: true  },
    { id: uid(), name: 'Car Insurance',  amount: 98.00,  dueDate: addDays(t, -8),  category: 'Insurance',       notes: '',             paid: false },
  ];
  save();
}

render();
