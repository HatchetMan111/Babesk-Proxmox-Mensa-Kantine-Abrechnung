#!/usr/bin/env python3
"""
babesk modern API
=================
 Schlanke JSON-API fuer eine moderne React-UI. Liest/schreibt direkt auf die
 bestehende babesk-MariaDB (Schema von LinuCC/babesk). Kein PHP-Code wird
 angefasst - die DB ist die einzige gemeinsame Basis.

 Auth: Username/Password gegen SystemUsers (md5-32 ODER pbkdf2 sha256:iter:salt:hash),
 danach JWT (Bearer). Passwort-Hashing ist zu babesk kompatibel.
"""
import base64
import hashlib
import hmac
import os
import time
from datetime import date, datetime, timedelta
from typing import Optional

import jwt
import pymysql
from fastapi import Depends, FastAPI, HTTPException, Header
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# ---------------- Konfiguration (aus Env, vom Installer gesetzt) ----------------
DB_HOST = os.environ.get("BABESK_DB_HOST", "localhost")
DB_NAME = os.environ.get("BABESK_DB_NAME", "babesk")
DB_USER = os.environ.get("BABESK_DB_USER", "babesk")
DB_PASS = os.environ.get("BABESK_DB_PASS", "")
JWT_SECRET = os.environ.get("BABESK_JWT_SECRET", os.urandom(32).hex())
JWT_TTL = int(os.environ.get("BABESK_JWT_TTL", str(12 * 3600)))  # 12 h
WEB_DIR = os.environ.get("BABESK_WEB_DIR", os.path.join(os.path.dirname(__file__), "..", "web", "dist"))

app = FastAPI(title="babesk modern API", version="1.0")


# ---------------- DB-Helfer ----------------
def db():
    conn = pymysql.connect(
        host=DB_HOST, user=DB_USER, password=DB_PASS, database=DB_NAME,
        charset="latin1", cursorclass=pymysql.cursors.DictCursor, autocommit=False,
    )
    return conn


def query(sql, params=None, one=False):
    conn = db()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
            rows = cur.fetchall()
        return (rows[0] if rows else None) if one else rows
    finally:
        conn.close()


def execute(sql, params=None, commit=True):
    conn = db()
    try:
        with conn.cursor() as cur:
            n = cur.execute(sql, params or ())
        if commit:
            conn.commit()
        return n
    finally:
        conn.close()


# ---------------- Passwort (babesk-kompatibel) ----------------
def verify_password(password: str, stored: str) -> bool:
    if not stored:
        return False
    # md5 (32 Zeichen) - babesk-Default (z. B. admin/root)
    if len(stored) == 32 and all(c in "0123456789abcdef" for c in stored.lower()):
        return hmac.compare_digest(hashlib.md5(password.encode("utf-8")).hexdigest(), stored.lower())
    # pbkdf2: sha256:iterations:salt_b64:hash_b64  (Salt = die b64-Zeichenkette selbst)
    parts = stored.split(":")
    if len(parts) == 4:
        algo, iters, salt_b64, hash_b64 = parts
        try:
            expected = base64.b64decode(hash_b64)
            dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"),
                                     salt_b64.encode("utf-8"), int(iters), len(expected))
            return hmac.compare_digest(dk, expected)
        except Exception:
            return False
    return False


# ---------------- Auth ----------------
def make_token(user_id: int) -> str:
    return jwt.encode({"uid": user_id, "exp": int(time.time()) + JWT_TTL}, JWT_SECRET, algorithm="HS256")


def current_user(authorization: Optional[str] = Header(None)) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Kein Token")
    token = authorization.split(" ", 1)[1].strip()
    try:
        data = jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
    except Exception:
        raise HTTPException(401, "Token ungueltig/abgelaufen")
    user = query("SELECT ID, name, forename, username, GID, credit, soli, locked FROM SystemUsers WHERE ID=%s",
                 (data.get("uid"),), one=True)
    if not user:
        raise HTTPException(401, "Benutzer nicht gefunden")
    return user


# ---------------- Models ----------------
class LoginIn(BaseModel):
    username: str
    password: str


class OrderIn(BaseModel):
    meal_id: int


# ---------------- Endpunkte ----------------
@app.post("/api/login")
def login(body: LoginIn):
    user = query("SELECT * FROM SystemUsers WHERE username=%s", (body.username,), one=True)
    if not user or user.get("locked") or not verify_password(body.password, user["password"]):
        raise HTTPException(401, "Benutzername oder Passwort falsch")
    # last_login pflegen (babesk-Format ist ein String)
    try:
        execute("UPDATE SystemUsers SET last_login=%s WHERE ID=%s",
                (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), user["ID"]))
    except Exception:
        pass
    return {"token": make_token(user["ID"]),
            "user": {"id": user["ID"], "username": user["username"],
                     "name": user["name"], "forename": user["forename"],
                     "credit": float(user["credit"]), "gid": user["GID"]}}


@app.get("/api/me")
def me(u=Depends(current_user)):
    return {"id": u["ID"], "username": u["username"], "name": u["name"],
            "forename": u["forename"], "credit": round(float(u["credit"]), 2), "gid": u["GID"]}


def _price_for_meal(meal_price_class, user_gid):
    """Preis aufloesen: Meal.price_class -> BabeskPriceClasses; passend zur Gruppe."""
    pc = query("SELECT * FROM BabeskPriceClasses WHERE ID=%s", (meal_price_class,), one=True)
    if not pc:
        return None
    # Bevorzugt die Preisgruppe (pc_ID) fuer die Gruppe des Users
    if user_gid is not None:
        match = query("SELECT price FROM BabeskPriceClasses WHERE pc_ID=%s AND GID=%s LIMIT 1",
                      (pc["pc_ID"], user_gid), one=True)
        if match:
            return float(match["price"])
    return float(pc["price"])


@app.get("/api/menu")
def menu(days: int = 7, u=Depends(current_user)):
    start = date.today()
    end = start + timedelta(days=max(1, min(days, 31)))
    meals = query(
        "SELECT ID, name, description, price_class, date, max_orders FROM BabeskMeals "
        "WHERE date BETWEEN %s AND %s ORDER BY date, ID", (start, end))
    # Bestellungen des Users in dem Zeitraum
    orders = query("SELECT MID FROM BabeskOrders WHERE UID=%s AND date BETWEEN %s AND %s",
                   (u["ID"], start, end))
    ordered = {o["MID"] for o in orders}
    # Zaehler je Meal (max_orders)
    counts = {}
    for r in query("SELECT MID, COUNT(*) c FROM BabeskOrders WHERE date BETWEEN %s AND %s GROUP BY MID",
                   (start, end)):
        counts[r["MID"]] = r["c"]
    out = {}
    for m in meals:
        price = _price_for_meal(m["price_class"], u["GID"])
        item = {
            "id": m["ID"], "name": m["name"], "description": m["description"],
            "date": m["date"].isoformat(), "price": price,
            "max_orders": m["max_orders"], "ordered": m["ID"] in ordered,
            "remaining": max(0, m["max_orders"] - counts.get(m["ID"], 0)),
        }
        out.setdefault(m["date"].isoformat(), []).append(item)
    return [{"date": d, "meals": meals} for d, meals in sorted(out.items())]


@app.get("/api/orders")
def orders(u=Depends(current_user)):
    rows = query(
        "SELECT o.ID, o.MID, o.date, o.fetched, m.name, m.price_class FROM BabeskOrders o "
        "JOIN BabeskMeals m ON m.ID=o.MID WHERE o.UID=%s ORDER BY o.date DESC, o.ID DESC", (u["ID"],))
    res = []
    for r in rows:
        res.append({"id": r["ID"], "meal_id": r["MID"], "name": r["name"],
                    "date": r["date"].isoformat(), "fetched": bool(r["fetched"]),
                    "price": _price_for_meal(r["price_class"], u["GID"])})
    return res


@app.post("/api/orders")
def place_order(body: OrderIn, u=Depends(current_user)):
    meal = query("SELECT * FROM BabeskMeals WHERE ID=%s", (body.meal_id,), one=True)
    if not meal:
        raise HTTPException(404, "Menue nicht gefunden")
    if meal["date"] < date.today():
        raise HTTPException(400, "Bestellschluss fuer dieses Menue ist vorbei")
    dup = query("SELECT ID FROM BabeskOrders WHERE MID=%s AND UID=%s", (body.meal_id, u["ID"]), one=True)
    if dup:
        raise HTTPException(400, "Dieses Menue hast du schon bestellt")
    cnt = query("SELECT COUNT(*) c FROM BabeskOrders WHERE MID=%s", (body.meal_id,), one=True)["c"]
    if cnt >= meal["max_orders"]:
        raise HTTPException(400, "Dieses Menue ist ausverkauft")
    price = _price_for_meal(meal["price_class"], u["GID"]) or 0.0
    conn = db()
    try:
        with conn.cursor() as cur:
            # Guthaben erneut prüfen (frisch)
            cur.execute("SELECT credit FROM SystemUsers WHERE ID=%s FOR UPDATE", (u["ID"],))
            credit = float(cur.fetchone()["credit"])
            if credit < price:
                conn.rollback()
                raise HTTPException(400, f"Nicht genug Guthaben (nötig {price:.2f} €, vorhanden {credit:.2f} €)")
            ip = b"\x00" * 16
            cur.execute("INSERT INTO BabeskOrders (MID, UID, date, IP) VALUES (%s,%s,%s,%s)",
                        (body.meal_id, u["ID"], meal["date"], ip))
            cur.execute("UPDATE SystemUsers SET credit=credit-%s WHERE ID=%s", (price, u["ID"]))
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "credit": round(credit - price, 2)}


@app.delete("/api/orders/{order_id}")
def cancel_order(order_id: int, u=Depends(current_user)):
    o = query("SELECT * FROM BabeskOrders WHERE ID=%s AND UID=%s", (order_id, u["ID"]), one=True)
    if not o:
        raise HTTPException(404, "Bestellung nicht gefunden")
    meal = query("SELECT * FROM BabeskMeals WHERE ID=%s", (o["MID"],), one=True)
    if meal and meal["date"] < date.today():
        raise HTTPException(400, "Stornierung nach Bestellschluss nicht mehr moeglich")
    price = _price_for_meal(meal["price_class"], u["GID"]) if meal else 0.0
    conn = db()
    try:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM BabeskOrders WHERE ID=%s AND UID=%s", (order_id, u["ID"]))
            if price:
                cur.execute("UPDATE SystemUsers SET credit=credit+%s WHERE ID=%s", (price, u["ID"]))
        conn.commit()
    finally:
        conn.close()
    return {"ok": True}


@app.get("/api/cards")
def cards(u=Depends(current_user)):
    rows = query("SELECT cardnumber FROM BabeskCards WHERE UID=%s", (u["ID"],))
    return [{"cardnumber": r["cardnumber"]} for r in rows]


@app.get("/api/health")
def health():
    return {"ok": True}


# ---------------- Static (gebauten React-App ausliefern, falls vorhanden) ----------------
if os.path.isdir(WEB_DIR):
    app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")