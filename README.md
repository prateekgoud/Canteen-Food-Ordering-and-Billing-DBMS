# Canteen Food Ordering & Billing Management System (DBMS Project 07)
MySQL 8 + Python Streamlit prototype.

## Structure
- `sql/` - `01_schema.sql` (tables, constraints, triggers, procedure, views), `02_sample_data.sql`, `03_queries.sql`
- `app/app.py` - Streamlit front-end
- `presentations/` - Review 1, Review 2, Review 3 slides
- `video/Video_Link.md` - public Google Drive link of the 5-minute demo
- `report/` - final project report; `screenshots/` - output screens

## Run
1. `mysql -u root -p < sql/01_schema.sql` then `mysql -u root -p < sql/02_sample_data.sql`
2. `pip install -r requirements.txt`
3. Set `DB_USER` / `DB_PASSWORD` (Windows: `set DB_PASSWORD=yourpass`; Linux/Mac: `export DB_PASSWORD=yourpass`)
4. `streamlit run app/app.py`

## Business rules enforced in the database
At least one item per order, positive quantities, no unavailable items, valid status flow (PLACED > PREPARING > READY > SERVED, cancel before READY), payment limit 10000 and no overpayment, stock never negative.
