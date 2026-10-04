from flask import Flask
from flask_cors import CORS
import os
from dotenv import load_dotenv

# Load .env ONLY for local/dev
if os.getenv("FLASK_ENV") != "production":
    load_dotenv()

# ---------------- Imports ----------------
from auth import auth
from cart import cart
from products import products
from orders import orders
from admin import admin

from error_handlers import (
    register_error_handlers,
    setup_logging,
    log_request_info,
    register_api_exception_handler
)
from security import limiter, SecurityHeaders

# ---------------- App Init ----------------
app = Flask(__name__)

# ---------------- Config ----------------
app.config["SECRET_KEY"] = os.getenv("SECRET_KEY")
app.config["JWT_SECRET_KEY"] = os.getenv("JWT_SECRET_KEY")
app.config["ENV"] = os.getenv("FLASK_ENV", "development")

if app.config["ENV"] == "testing":
    app.config["RATELIMIT_ENABLED"] = False

# ---------------- CORS ----------------
CORS(app, origins=os.getenv("CORS_ORIGINS", "http://localhost:4200").split(","))

# ---------------- Production Checks ----------------
if app.config["ENV"] == "production":
    assert os.getenv("SECRET_KEY"), "SECRET_KEY env var is REQUIRED in production"
    assert os.getenv("JWT_SECRET_KEY"), "JWT_SECRET_KEY env var is REQUIRED in production"

# ---------------- Extensions ----------------
limiter.init_app(app)

# ---------------- Logging & Errors ----------------
setup_logging(app)
register_error_handlers(app)
register_api_exception_handler(app)
log_request_info(app)

# ---------------- Security Headers ----------------
@app.after_request
def after_request(response):
    return SecurityHeaders.add_security_headers(response)

# ---------------- Blueprints ----------------
app.register_blueprint(auth, url_prefix="/api")
app.register_blueprint(cart, url_prefix="/api/cart")
app.register_blueprint(products, url_prefix="/api/products")
app.register_blueprint(orders, url_prefix="/api/orders")
app.register_blueprint(admin, url_prefix="/api/admin")

# ---------------- Health (REQUIRED FOR ALB) ----------------
@app.route("/", methods=["GET"])
def home():
    return {"status": "ok", "service": "backend"}, 200

@app.route("/health", methods=["GET"])
def health():
    return {"status": "healthy"}, 200

# ---------------- Run ----------------
if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=int(os.getenv("PORT", 5000)),
        debug=os.getenv("FLASK_DEBUG", "false").lower() == "true"
    )
