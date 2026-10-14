import os, re
from decimal import Decimal
import mysql.connector
import pandas as pd
import streamlit as st

st.set_page_config(page_title="Canteen DBMS", page_icon="🍽️", layout="wide")

def conn():
    return mysql.connector.connect(
        host=os.getenv("DB_HOST", "localhost"), user=os.getenv("DB_USER", "root"),
        password=os.getenv("DB_PASSWORD", ""), database=os.getenv("DB_NAME", "canteen_db"))

def q(sql, p=()):
    c = conn(); cur = c.cursor(dictionary=True)
    try:
        cur.execute(sql, p)
        rows = [{k: float(v) if isinstance(v, Decimal) else v for k, v in r.items()} for r in cur.fetchall()]
        return pd.DataFrame(rows)
    finally:
        c.close()

def run(steps):
    """Run statements as ONE transaction; rollback and show DB error on failure."""
    c = conn(); cur = c.cursor()
    try:
        for s, p in steps:
            cur.execute(s, p)
        c.commit(); return True
    except mysql.connector.Error as e:
        c.rollback(); st.error(f"Database rejected this: {e.msg}"); return False
    finally:
        c.close()

def place_order(cust, lines):
    c = conn(); cur = c.cursor()
    try:
        cur.execute("INSERT INTO orders(customer_id) VALUES (%s)", (cust,)); oid = cur.lastrowid
        for iid, qty in lines:
            cur.execute("INSERT INTO order_item(order_id,item_id,quantity) VALUES (%s,%s,%s)", (oid, iid, qty))
        c.commit(); return oid
    except mysql.connector.Error as e:
        c.rollback(); st.error(f"Order rejected: {e.msg}"); return None
    finally:
        c.close()

def show(df, **kw):
    if df.empty: st.info("No records.")
    else: st.dataframe(df, use_container_width=True, hide_index=True, **kw)

try:
    conn().close()
except mysql.connector.Error as e:
    st.error(f"Cannot connect to MySQL: {e.msg}. Set DB_HOST / DB_USER / DB_PASSWORD and run the SQL scripts first.")
    st.stop()

pg = st.sidebar.radio("🍽️ Canteen DBMS", ["Dashboard", "Menu", "New Order", "Kitchen", "Ingredients", "Billing & Payment", "Reports"])

if pg == "Dashboard":
    st.header("Dashboard")
    r = q("SELECT * FROM v_revenue").iloc[0]
    a, b, c, d = st.columns(4)
    a.metric("Billed", f"₹{r['billed']:.2f}"); b.metric("Collected", f"₹{r['collected']:.2f}")
    c.metric("Outstanding", f"₹{r['outstanding']:.2f}")
    d.metric("Pending orders", len(q("SELECT order_id FROM v_pending_orders")))
    st.subheader("Low stock")
    show(q("SELECT name, stock_qty, reorder_level, unit FROM ingredient WHERE stock_qty <= reorder_level"))

elif pg == "Menu":
    st.header("Menu maintenance")
    s = st.text_input("🔍 Search item")
    show(q("SELECT f.item_id, f.name, c.name AS category, f.price, f.is_available FROM food_item f "
           "JOIN category c ON c.category_id=f.category_id WHERE f.name LIKE %s ORDER BY c.name, f.name", (f"%{s}%",)))
    cmap = {r.category_id: r.name for r in q("SELECT * FROM category").itertuples()}
    items = {r.item_id: r.name for r in q("SELECT item_id, name FROM food_item ORDER BY name").itertuples()}
    a, b = st.columns(2)
    with a.form("add"):
        st.subheader("Add item")
        n = st.text_input("Name"); cat = st.selectbox("Category", list(cmap), format_func=cmap.get)
        pr = st.number_input("Price (₹)", min_value=0.0, step=1.0)
        if st.form_submit_button("Add"):
            if not n.strip() or pr <= 0: st.warning("Enter a name and a price above 0.")
            elif run([("INSERT INTO food_item(category_id,name,price) VALUES (%s,%s,%s)", (int(cat), n.strip(), pr))]): st.rerun()
    with b.form("upd"):
        st.subheader("Update price / availability")
        it = st.selectbox("Item", list(items), format_func=items.get)
        np_ = st.number_input("New price (₹)", min_value=0.0, step=1.0); av = st.checkbox("Available", True)
        if st.form_submit_button("Update"):
            if np_ <= 0: st.warning("Price must be above 0.")
            elif run([("UPDATE food_item SET price=%s, is_available=%s WHERE item_id=%s", (np_, av, int(it)))]): st.rerun()

elif pg == "New Order":
    st.header("Order entry")
    cm = {0: "Walk-in"}; cm.update({r.customer_id: f"{r.name} ({r.phone})" for r in q("SELECT * FROM customer ORDER BY name").itertuples()})
    cid = st.selectbox("Customer", list(cm), format_func=cm.get)
    with st.expander("Register new customer"):
        with st.form("nc"):
            nm = st.text_input("Name"); ph = st.text_input("Phone (10 digits)")
            if st.form_submit_button("Save"):
                if not nm.strip() or not re.fullmatch(r"\d{10}", ph): st.warning("Valid name and 10-digit phone required.")
                elif run([("INSERT INTO customer(name,phone) VALUES (%s,%s)", (nm.strip(), ph))]): st.rerun()
    im = {r.item_id: (r.name, r.price) for r in q("SELECT item_id,name,price FROM food_item WHERE is_available ORDER BY name").itertuples()}
    pick = st.multiselect("Items (only available items are listed)", list(im), format_func=lambda i: f"{im[i][0]} - ₹{im[i][1]:.0f}")
    lines = [(int(i), st.number_input(f"{im[i][0]} quantity", 1, 50, 1, key=f"q{i}")) for i in pick]
    st.write(f"**Subtotal: ₹{sum(im[i][1]*n for i, n in lines):.2f}** (5% tax added at billing)")
    if st.button("Place order", type="primary"):
        if not lines: st.warning("Add at least one item.")
        else:
            oid = place_order(None if cid == 0 else int(cid), lines)
            if oid: st.success(f"Order #{oid} placed.")

elif pg == "Kitchen":
    st.header("Kitchen status")
    df = q("SELECT * FROM v_pending_orders ORDER BY order_time"); show(df)
    nxt = {"PLACED": ["PREPARING", "CANCELLED"], "PREPARING": ["READY", "CANCELLED"], "READY": ["SERVED"]}
    if not df.empty:
        oid = st.selectbox("Order", df.order_id.tolist())
        cur = df[df.order_id == oid].status.iloc[0]
        new = st.selectbox(f"Move #{oid} from {cur} to", nxt[cur])
        if st.button("Update status"):
            if run([("UPDATE orders SET status=%s WHERE order_id=%s", (new, int(oid)))]): st.rerun()

elif pg == "Ingredients":
    st.header("Ingredient stock & issue")
    show(q("SELECT ingredient_id, name, unit, stock_qty, reorder_level, stock_qty <= reorder_level AS low_stock FROM ingredient"))
    ing = {r.ingredient_id: f"{r.name} ({r.unit})" for r in q("SELECT * FROM ingredient").itertuples()}
    with st.form("stk"):
        i = st.selectbox("Ingredient", list(ing), format_func=ing.get)
        kind = st.radio("Action", ["ISSUE (to kitchen)", "RESTOCK"], horizontal=True)
        qty = st.number_input("Quantity", min_value=0.0, step=0.5)
        if st.form_submit_button("Submit"):
            if qty <= 0: st.warning("Quantity must be above 0.")
            else:
                ch = -qty if kind.startswith("ISSUE") else qty
                if run([("UPDATE ingredient SET stock_qty = stock_qty + %s WHERE ingredient_id=%s", (ch, int(i))),
                        ("INSERT INTO stock_txn(ingredient_id,change_qty,txn_type) VALUES (%s,%s,%s)", (int(i), ch, kind.split()[0]))]): st.rerun()

elif pg == "Billing & Payment":
    st.header("Billing & payment")
    ub = q("SELECT o.order_id, o.status FROM orders o WHERE o.status <> 'CANCELLED' AND NOT EXISTS (SELECT 1 FROM bill b WHERE b.order_id=o.order_id)")
    st.subheader("Generate bill")
    if ub.empty: st.info("All orders are billed.")
    else:
        oid = st.selectbox("Order to bill", ub.order_id.tolist())
        if st.button("Generate bill") and run([("CALL generate_bill(%s)", (int(oid),))]): st.rerun()
    bills = q("SELECT b.bill_id, b.order_id, b.subtotal, b.tax, b.total, COALESCE(SUM(p.amount),0) AS paid, b.status "
              "FROM bill b LEFT JOIN payment p ON p.bill_id=b.bill_id GROUP BY b.bill_id, b.order_id, b.subtotal, b.tax, b.total, b.status ORDER BY b.bill_id DESC")
    show(bills)
    due = bills[bills.status == "UNPAID"] if not bills.empty else bills
    st.subheader("Take payment")
    if due.empty: st.info("No unpaid bills.")
    else:
        bid = st.selectbox("Bill", due.bill_id.tolist())
        amt_due = float(due[due.bill_id == bid].total.iloc[0] - due[due.bill_id == bid].paid.iloc[0])
        amt = st.number_input("Amount (₹)", 0.0, step=1.0, value=amt_due); m = st.selectbox("Method", ["CASH", "UPI", "CARD"])
        if st.button("Pay"):
            if amt <= 0: st.warning("Amount must be above 0.")
            elif run([("INSERT INTO payment(bill_id,amount,method) VALUES (%s,%s,%s)", (int(bid), amt, m))]): st.rerun()

elif pg == "Reports":
    st.header("Sales & operations reports")
    tabs = st.tabs(["Daily sales", "Popular items", "Category sales", "Pending", "Ingredient use", "Cancellations", "Revenue", "Find orders"])
    views = ["v_daily_sales", "v_popular_items", "v_category_sales", "v_pending_orders", "v_ingredient_consumption", "v_cancellations", "v_revenue"]
    for t, v in zip(tabs, views):
        with t:
            df = q(f"SELECT * FROM {v}"); show(df)
            if not df.empty:
                if v in ("v_daily_sales", "v_popular_items", "v_category_sales"): st.bar_chart(df.set_index(df.columns[0])["revenue"])
                st.download_button("Download CSV", df.to_csv(index=False), f"{v}.csv")
    with tabs[7]:
        s = st.text_input("Search by order ID, customer or status")
        show(q("SELECT o.order_id, o.order_time, COALESCE(c.name,'Walk-in') AS customer, o.status FROM orders o "
               "LEFT JOIN customer c ON c.customer_id=o.customer_id WHERE CAST(o.order_id AS CHAR)=%s OR c.name LIKE %s OR o.status LIKE %s ORDER BY o.order_id DESC",
               (s, f"%{s}%", f"%{s}%")))
