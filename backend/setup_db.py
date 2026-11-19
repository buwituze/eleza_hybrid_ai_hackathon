"""
setup_db.py — prepare a fresh PostgreSQL database (e.g. Neon) for Eleza.

    python setup_db.py

1. Creates the schema, if the database is empty:
   database/schema.sql (tables, triggers) → column migrations →
   schema.sql views → view migrations. (The views need columns that the
   migrations add, so schema.sql cannot be run on its own.)
2. Creates demo accounts for testing/judging, if DEMO_PASSWORD is set:
   one facility plus a platform admin, a hospital admin and a doctor.

Safe to run again: existing tables and accounts are left alone.

Uses the same DB_* variables as the backend (see .env.example). For Neon set
PGSSLMODE=require. Demo data is fake — never put real patient data here.
"""
import os
import sys
from pathlib import Path

import bcrypt
import psycopg2
from dotenv import load_dotenv

load_dotenv()

DB_DIR = Path(__file__).parent / "database"
VIEWS_MARKER = "-- Views for doctor dashboard"

# Migrations that add columns (must run before the views are created).
COLUMN_MIGRATIONS = ["add_new_system_fields.sql", "add_doctor_specialty.sql"]
# Migrations that redefine views (run after the views exist).
VIEW_MIGRATIONS = [
    "fix_v_facility_stats_missing_columns.sql",
    "add_age_to_patient_list_view.sql",
    "fix_v_queue_overview_missing_exams.sql",
]

DEMO_FACILITY = {
    "name": "Eleza Demo Hospital",
    "primary_email": "facility@eleza.demo",
    "primary_phone": "+250700000000",
    "location": "Kigali, Rwanda",
}
DEMO_USERS = [
    # (email, full name, role, linked to the demo facility, specialty)
    ("platform.admin@eleza.demo", "Demo Platform Admin", "platform_admin", False, None),
    ("hospital.admin@eleza.demo", "Demo Hospital Admin", "hospital_admin", True, None),
    ("doctor@eleza.demo", "Demo Doctor", "doctor", True, "generalist"),
]


def connect():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME", "pre_consultation_db"),
        user=os.getenv("DB_USER", "postgres"),
        password=os.getenv("DB_PASSWORD", ""),
        connect_timeout=15,
    )


def run_sql(conn, label: str, sql: str, required: bool = True) -> bool:
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()
        print(f"  ✅ {label}")
        return True
    except Exception as e:
        conn.rollback()
        if required:
            raise RuntimeError(f"{label} failed: {e}") from e
        print(f"  ⚠️  {label} skipped: {str(e).strip().splitlines()[0]}")
        return False


def schema_exists(conn) -> bool:
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass('public.users') IS NOT NULL")
        return cur.fetchone()[0]


def create_schema(conn) -> None:
    schema = (DB_DIR / "schema.sql").read_text(encoding="utf-8")
    if VIEWS_MARKER not in schema:
        raise RuntimeError(f"'{VIEWS_MARKER}' not found in schema.sql")
    tables, views = schema.split(VIEWS_MARKER, 1)

    print("Creating schema…")
    run_sql(conn, "schema.sql (tables, triggers)", tables)
    for name in COLUMN_MIGRATIONS:
        run_sql(conn, name, (DB_DIR / "migrations" / name).read_text(encoding="utf-8"))
    run_sql(conn, "schema.sql (views)", views)
    for name in VIEW_MIGRATIONS:
        run_sql(conn, name, (DB_DIR / "migrations" / name).read_text(encoding="utf-8"),
                required=False)


def seed_demo(conn, password: str) -> None:
    pw_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12)).decode()
    with conn.cursor() as cur:
        cur.execute("SELECT facility_id FROM facility WHERE name = %s", (DEMO_FACILITY["name"],))
        row = cur.fetchone()
        if row:
            facility_id = row[0]
        else:
            cur.execute(
                "INSERT INTO facility (name, primary_email, primary_phone, location) "
                "VALUES (%(name)s, %(primary_email)s, %(primary_phone)s, %(location)s) "
                "RETURNING facility_id",
                DEMO_FACILITY,
            )
            facility_id = cur.fetchone()[0]
            print(f"  ✅ facility '{DEMO_FACILITY['name']}' (id {facility_id})")

        for email, name, role, linked, specialty in DEMO_USERS:
            cur.execute("SELECT user_id FROM users WHERE email = %s", (email,))
            row = cur.fetchone()
            if row:
                user_id = row[0]
                print(f"  ↩️  {role:<15} {email} (already exists, password unchanged)")
            else:
                cur.execute(
                    "INSERT INTO users (email, password_hash, full_name, role, facility_id, specialty) "
                    "VALUES (%s, %s, %s, %s, %s, %s) RETURNING user_id",
                    (email, pw_hash, name, role, facility_id if linked else None, specialty),
                )
                user_id = cur.fetchone()[0]
                print(f"  ✅ {role:<15} {email}")
            if role == "hospital_admin":
                cur.execute(
                    "UPDATE facility SET admin_user_id = %s "
                    "WHERE facility_id = %s AND admin_user_id IS NULL",
                    (user_id, facility_id),
                )
    conn.commit()


def main() -> int:
    host = os.getenv("DB_HOST", "localhost")
    print(f"Database: {host}:{os.getenv('DB_PORT', '5432')}/{os.getenv('DB_NAME', 'pre_consultation_db')}")
    try:
        conn = connect()
    except Exception as e:
        print(f"❌ Cannot connect: {e}")
        if "neon.tech" in host and os.getenv("PGSSLMODE") != "require":
            print("   Neon needs SSL: set PGSSLMODE=require")
        return 1

    try:
        if schema_exists(conn):
            print("Schema already exists — skipping table creation.")
        else:
            create_schema(conn)

        password = os.getenv("DEMO_PASSWORD", "")
        if len(password) >= 8:
            print("Demo accounts (password = DEMO_PASSWORD):")
            seed_demo(conn, password)
        else:
            print("ℹ️  DEMO_PASSWORD not set (min 8 characters) — no demo accounts created.")
        print("✅ Database ready")
        return 0
    except Exception as e:
        print(f"❌ {e}")
        return 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
