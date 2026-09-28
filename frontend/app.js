/*
 * Frontend logic for the ShopStream demo UI.
 *
 * IMPORTANT: all backend calls use RELATIVE paths under /api/.
 * The frontend and backend are separate containers/services — the browser
 * cannot reach the backend on localhost:5000. The ALB routes /api/* to the
 * backend target group and / to this frontend (see terraform/ecs.tf).
 *
 * Element IDs this file depends on (all present in index.html):
 *   health-badge, order-id, customer-id, product-id, quantity, amount,
 *   submit-order, form-status, orders, refresh, and any .product-card
 */

const API_BASE = "/api";

function $(id) {
  return document.getElementById(id);
}

function money(value) {
  return Number(value).toLocaleString(undefined, {
    style: "currency",
    currency: "USD",
  });
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[char]));
}

/** Generates a friendly placeholder order id so the demo form isn't blank. */
function generateOrderId() {
  const stamp = Date.now().toString(36).toUpperCase().slice(-6);
  return `ORD-${stamp}`;
}

/* ---------------------------------------------------------------------- */
/* Health check                                                            */
/* ---------------------------------------------------------------------- */

async function checkHealth() {
  const badge = $("health-badge");
  try {
    // Must be /api/health, not /health: only /api/* is routed to the backend.
    const res = await fetch(`${API_BASE}/health`);
    if (!res.ok) throw new Error(`status ${res.status}`);
    badge.textContent = "● API healthy";
    badge.className = "badge badge-ok";
  } catch (err) {
    badge.textContent = "● API unreachable";
    badge.className = "badge badge-bad";
  }
}

/* ---------------------------------------------------------------------- */
/* Orders list                                                             */
/* ---------------------------------------------------------------------- */

async function loadOrders() {
  const container = $("orders");
  const refreshBtn = $("refresh");

  refreshBtn.disabled = true;
  container.innerHTML = '<p class="muted loading-row">Loading orders…</p>';

  try {
    const res = await fetch(`${API_BASE}/orders?limit=25`);
    if (!res.ok) throw new Error(`Request failed with status ${res.status}`);

    const orders = await res.json();

    if (!Array.isArray(orders) || orders.length === 0) {
      container.innerHTML =
        '<p class="muted loading-row">No orders yet — submit one above to see it here.</p>';
      return;
    }

    container.innerHTML = orders
      .map(
        (order) => `
        <div class="order-row">
          <span class="order-id">${escapeHtml(order.order_id)}</span>
          <span>Customer ${escapeHtml(order.customer_id)}</span>
          <span>Product ${escapeHtml(order.product_id)}</span>
          <span>x${escapeHtml(order.quantity)}</span>
          <span class="amount">${money(order.amount)}</span>
        </div>`
      )
      .join("");
  } catch (err) {
    container.innerHTML = `<p class="error">Could not load orders: ${escapeHtml(
      err.message
    )}</p>`;
  } finally {
    refreshBtn.disabled = false;
  }
}

/* ---------------------------------------------------------------------- */
/* Order form                                                              */
/* ---------------------------------------------------------------------- */

function readOrderForm() {
  return {
    order_id: $("order-id").value.trim(),
    customer_id: Number($("customer-id").value),
    product_id: Number($("product-id").value),
    quantity: Number($("quantity").value),
    amount: Number($("amount").value),
  };
}

function validateOrder(payload) {
  if (!payload.order_id) return "Order ID is required.";
  if (!payload.customer_id) return "Customer ID is required.";
  if (!payload.product_id) return "Product ID is required.";
  if (!payload.quantity || payload.quantity <= 0) return "Quantity must be at least 1.";
  if (!payload.amount || payload.amount < 0) return "Amount must be a positive number.";
  return null;
}

function setStatus(message, kind) {
  const status = $("form-status");
  status.textContent = message;
  status.className = `status ${kind}`;
}

async function submitOrder() {
  const button = $("submit-order");
  const payload = readOrderForm();

  const validationError = validateOrder(payload);
  if (validationError) {
    setStatus(validationError, "error");
    return;
  }

  button.disabled = true;
  setStatus("Submitting…", "muted");

  try {
    const res = await fetch(`${API_BASE}/orders`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const body = await res.json();

    if (!res.ok) {
      throw new Error(body.error || `status ${res.status}`);
    }

    setStatus(`✓ Order ${body.order_id} created.`, "ok");

    // Reset for the next demo order, but keep customer/product/quantity
    // pre-filled so repeated testing is fast.
    $("order-id").value = generateOrderId();
    $("amount").value = "";
    $("amount").focus();

    await loadOrders();
  } catch (err) {
    setStatus(`Failed: ${err.message}`, "error");
  } finally {
    button.disabled = false;
  }
}

/* ---------------------------------------------------------------------- */
/* Catalog — click a product card to prefill the order form               */
/* ---------------------------------------------------------------------- */

function wireCatalog() {
  const cards = document.querySelectorAll(".product-card");

  cards.forEach((card) => {
    card.style.cursor = "pointer";
    card.setAttribute("role", "button");
    card.setAttribute("tabindex", "0");

    const metaText = card.querySelector(".product-meta")?.textContent || "";
    const priceText = card.querySelector(".product-price")?.textContent || "";
    const productIdMatch = metaText.match(/Product ID\s+(\d+)/i);
    const priceMatch = priceText.match(/([\d.]+)/);

    const fillFromCard = () => {
      if (productIdMatch) $("product-id").value = productIdMatch[1];
      if (priceMatch) $("amount").value = priceMatch[1];
      if (!$("order-id").value) $("order-id").value = generateOrderId();

      document.getElementById("order").scrollIntoView({ behavior: "smooth", block: "start" });
      $("customer-id").focus();

      setStatus("Product added — set a Customer ID and submit.", "muted");
    };

    card.addEventListener("click", fillFromCard);
    card.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        fillFromCard();
      }
    });
  });
}

/* ---------------------------------------------------------------------- */
/* Init                                                                     */
/* ---------------------------------------------------------------------- */

document.addEventListener("DOMContentLoaded", () => {
  $("order-id").value = generateOrderId();
  $("submit-order").addEventListener("click", submitOrder);
  $("refresh").addEventListener("click", loadOrders);

  // Enter key submits from any field inside the order form
  document.querySelector(".form-grid").addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      submitOrder();
    }
  });

  wireCatalog();
  checkHealth();
  loadOrders();
});