
"""
Security utilities and middleware for the Flask application
"""
from functools import wraps
from flask import request, jsonify, current_app
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import jwt
import re
import html
import os
from datetime import datetime, timedelta
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize rate limiter
limiter = Limiter(
    key_func=get_remote_address,
    storage_uri=os.getenv('RATELIMIT_STORAGE_URL', 'memory://'),
    default_limits=["200 per day", "50 per hour"]
)

class SecurityValidator:
    """Input validation and sanitization utilities"""

    @staticmethod
    def validate_email(email):
        """Validate email format"""
        if not email or len(email) > 254:
            return False

        pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        return re.match(pattern, email) is not None

    @staticmethod
    def validate_password(password):
        """Validate password strength"""
        if not password or len(password) < 8:
            return False, "Password must be at least 8 characters long"

        if not re.search(r'[A-Z]', password):
            return False, "Password must contain at least one uppercase letter"

        if not re.search(r'[a-z]', password):
            return False, "Password must contain at least one lowercase letter"

        if not re.search(r'\d', password):
            return False, "Password must contain at least one number"

        return True, "Password is valid"

    @staticmethod
    def sanitize_input(input_string):
        """Sanitize user input to prevent XSS"""
        if not input_string:
            return ""

        # HTML escape
        sanitized = html.escape(str(input_string))

        # Remove potentially dangerous characters
        sanitized = re.sub(r'[<>"\']', '', sanitized)

        return sanitized.strip()

    @staticmethod
    def validate_phone(phone):
        """Validate phone number format"""
        if not phone:
            return True  # Phone is optional

        # Remove all non-digit characters
        digits_only = re.sub(r'\D', '', phone)

        # Check if it's a valid length (10-15 digits)
        return 10 <= len(digits_only) <= 15

def token_required(f):
    """Decorator to require valid JWT token"""
    @wraps(f)
    def decorated(*args, **kwargs):
        token = None

        # Check for token in Authorization header
        if 'Authorization' in request.headers:
            auth_header = request.headers['Authorization']
            try:
                token = auth_header.split(" ")[1]  # Bearer <token>
            except IndexError:
                return jsonify({'success': False, 'message': 'Invalid token format'}), 401

        if not token:
            return jsonify({'success': False, 'message': 'Token is missing'}), 401

        try:
            # Decode the token
            data = jwt.decode(
                token,
                os.getenv('JWT_SECRET_KEY'),
                algorithms=['HS256']
            )
            current_user_id = data['user_id']
            current_user_role = data.get('role', 'customer')

            # Add user info to request context
            request.current_user_id = current_user_id
            request.current_user_role = current_user_role

        except jwt.ExpiredSignatureError:
            return jsonify({'success': False, 'message': 'Token has expired'}), 401
        except jwt.InvalidTokenError:
            return jsonify({'success': False, 'message': 'Token is invalid'}), 401
        except Exception as e:
            logger.error(f"Token validation error: {str(e)}")
            return jsonify({'success': False, 'message': 'Token validation failed'}), 401

        return f(*args, **kwargs)

    return decorated

def admin_required(f):
    """Decorator to require admin role"""
    @wraps(f)
    @token_required
    def decorated(*args, **kwargs):
        if not hasattr(request, 'current_user_role') or request.current_user_role != 'admin':
            return jsonify({'success': False, 'message': 'Admin access required'}), 403

        return f(*args, **kwargs)

    return decorated

def validate_json_input(required_fields=None, optional_fields=None):
    """Decorator to validate JSON input"""
    def decorator(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            if not request.is_json:
                return jsonify({'success': False, 'message': 'Content-Type must be application/json'}), 400

            data = request.get_json()
            if not data:
                return jsonify({'success': False, 'message': 'No JSON data provided'}), 400

            # Check required fields
            if required_fields:
                missing_fields = [field for field in required_fields if field not in data or not data[field]]
                if missing_fields:
                    return jsonify({
                        'success': False,
                        'message': f'Missing required fields: {", ".join(missing_fields)}'
                    }), 400

            # Sanitize all string inputs
            sanitized_data = {}
            all_fields = (required_fields or []) + (optional_fields or [])

            for field in all_fields:
                if field in data:
                    if isinstance(data[field], str):
                        sanitized_data[field] = SecurityValidator.sanitize_input(data[field])
                    else:
                        sanitized_data[field] = data[field]

            # Add sanitized data to request
            request.validated_json = sanitized_data

            return f(*args, **kwargs)

        return decorated
    return decorator

def generate_csrf_token():
    """Generate CSRF token"""
    import secrets
    return secrets.token_urlsafe(32)

def validate_csrf_token(token, session_token):
    """Validate CSRF token"""
    return token and session_token and token == session_token

class SecurityHeaders:
    """Security headers middleware"""

    @staticmethod
    def add_security_headers(response):
        """Add security headers to response"""
        # Prevent clickjacking
        response.headers['X-Frame-Options'] = 'DENY'

        # Prevent MIME type sniffing
        response.headers['X-Content-Type-Options'] = 'nosniff'

        # XSS Protection
        response.headers['X-XSS-Protection'] = '1; mode=block'

        # Strict Transport Security (HTTPS only)
        response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'

        # Content Security Policy
        response.headers['Content-Security-Policy'] = (
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: https:; "
            "font-src 'self' https:; "
            "connect-src 'self'"
        )

        # Referrer Policy
        response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'

        # Cache Control - prevent 10-minute default caching issue
        # Allow browser cache but validate with server
        response.headers['Cache-Control'] = 'public, max-age=300, must-revalidate'

        return response

def log_security_event(event_type, user_id=None, ip_address=None, details=None):
    """Log security-related events"""
    logger.warning(f"SECURITY EVENT: {event_type} | User: {user_id} | IP: {ip_address} | Details: {details}")

# Rate limiting decorators
def rate_limit_auth(f):
    """Rate limit for authentication endpoints"""
    @wraps(f)
    @limiter.limit("5 per minute")
    def decorated(*args, **kwargs):
        return f(*args, **kwargs)
    return decorated

def rate_limit_api(f):
    """Rate limit for general API endpoints"""
    @wraps(f)
    @limiter.limit("100 per minute")
    def decorated(*args, **kwargs):
        return f(*args, **kwargs)
    return decorated
