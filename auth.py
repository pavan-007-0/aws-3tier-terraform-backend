from flask import Blueprint, request, jsonify, current_app
from db import get_connection
from werkzeug.security import generate_password_hash, check_password_hash
import jwt
import datetime
import os
from security import (
    SecurityValidator, 
    validate_json_input, 
    rate_limit_auth, 
    log_security_event,
    token_required
)
from error_handlers import APIException

auth = Blueprint("auth", __name__)

@auth.route("/register", methods=["POST"])
@rate_limit_auth
@validate_json_input(
    required_fields=['name', 'email', 'password'],
    optional_fields=['phone']
)
def register():
    data = request.validated_json
    name = data.get("name")
    email = data.get("email")
    password = data.get("password")
    phone = data.get("phone")

    # Validate email format
    if not SecurityValidator.validate_email(email):
        log_security_event("INVALID_EMAIL_REGISTRATION", ip_address=request.remote_addr, details=email)
        raise APIException("Invalid email format", 400)

    # Validate password strength
    is_valid, message = SecurityValidator.validate_password(password)
    if not is_valid:
        log_security_event("WEAK_PASSWORD_REGISTRATION", ip_address=request.remote_addr)
        raise APIException(message, 400)

    # Validate phone if provided
    if phone and not SecurityValidator.validate_phone(phone):
        raise APIException("Invalid phone number format", 400)

    conn = get_connection()
    cursor = conn.cursor()

    try:
        # Check existing email
        cursor.execute("SELECT id FROM users WHERE email=%s", (email,))
        if cursor.fetchone():
            log_security_event("DUPLICATE_EMAIL_REGISTRATION", ip_address=request.remote_addr, details=email)
            raise APIException("Email already exists", 409)

        # Hash password with stronger method
        hashed_password = generate_password_hash(password, method='pbkdf2:sha256', salt_length=16)
        
        # Insert user with parameterized query
        cursor.execute(
            "INSERT INTO users (name, email, password, phone, role, is_active) VALUES (%s, %s, %s, %s, %s, %s)",
            (name, email, hashed_password, phone, 'customer', True)
        )
        conn.commit()
        
        user_id = cursor.lastrowid
        log_security_event("USER_REGISTERED", user_id=user_id, ip_address=request.remote_addr)
        
        return jsonify({
            "success": True, 
            "message": "Registration successful",
            "user_id": user_id
        }), 201

    except APIException:
        raise
    except Exception as e:
        conn.rollback()
        current_app.logger.error(f"Registration error: {str(e)}")
        raise APIException("Registration failed", 500)
    finally:
        cursor.close()
        conn.close()

@auth.route("/login", methods=["POST"])
@rate_limit_auth
@validate_json_input(required_fields=['email', 'password'])
def login():
    data = request.validated_json
    email = data.get("email")
    password = data.get("password")

    # Validate email format
    if not SecurityValidator.validate_email(email):
        log_security_event("INVALID_EMAIL_LOGIN", ip_address=request.remote_addr, details=email)
        raise APIException("Invalid email format", 400)

    conn = get_connection()
    cursor = conn.cursor(dictionary=True)
    
    try:
        cursor.execute("SELECT * FROM users WHERE email=%s AND is_active=TRUE", (email,))
        user = cursor.fetchone()
        
        if not user or not check_password_hash(user["password"], password):
            log_security_event("FAILED_LOGIN_ATTEMPT", ip_address=request.remote_addr, details=email)
            raise APIException("Invalid credentials", 401)

        # Generate access token
        access_token_payload = {
            "user_id": user["id"],
            "email": user["email"],
            "role": user["role"],
            "exp": datetime.datetime.utcnow() + datetime.timedelta(
                seconds=int(os.getenv('JWT_ACCESS_TOKEN_EXPIRES', 3600))
            )
        }
        
        access_token = jwt.encode(
            access_token_payload,
            os.getenv('JWT_SECRET_KEY'),
            algorithm="HS256"
        )

        # Generate refresh token
        refresh_token_payload = {
            "user_id": user["id"],
            "type": "refresh",
            "exp": datetime.datetime.utcnow() + datetime.timedelta(
                seconds=int(os.getenv('JWT_REFRESH_TOKEN_EXPIRES', 2592000))
            )
        }
        
        refresh_token = jwt.encode(
            refresh_token_payload,
            os.getenv('JWT_SECRET_KEY'),
            algorithm="HS256"
        )

        # Update last login
        cursor.execute(
            "UPDATE users SET updated_at=CURRENT_TIMESTAMP WHERE id=%s",
            (user["id"],)
        )
        conn.commit()

        log_security_event("SUCCESSFUL_LOGIN", user_id=user["id"], ip_address=request.remote_addr)

        return jsonify({
            "success": True,
            "access_token": access_token,
            "refresh_token": refresh_token,
            "user": {
                "id": user["id"],
                "name": user["name"],
                "email": user["email"],
                "role": user["role"],
                "phone": user["phone"]
            }
        })

    except APIException:
        raise
    except Exception as e:
        current_app.logger.error(f"Login error: {str(e)}")
        raise APIException("Login failed", 500)
    finally:
        cursor.close()
        conn.close()

@auth.route("/refresh", methods=["POST"])
@rate_limit_auth
def refresh_token():
    """Refresh access token using refresh token"""
    data = request.get_json()
    refresh_token = data.get('refresh_token') if data else None
    
    if not refresh_token:
        raise APIException("Refresh token is required", 400)
    
    try:
        # Decode refresh token
        payload = jwt.decode(
            refresh_token,
            os.getenv('JWT_SECRET_KEY'),
            algorithms=['HS256']
        )
        
        if payload.get('type') != 'refresh':
            raise APIException("Invalid token type", 401)
        
        user_id = payload['user_id']
        
        # Get user details
        conn = get_connection()
        cursor = conn.cursor(dictionary=True)
        cursor.execute("SELECT * FROM users WHERE id=%s AND is_active=TRUE", (user_id,))
        user = cursor.fetchone()
        cursor.close()
        conn.close()
        
        if not user:
            raise APIException("User not found", 401)
        
        # Generate new access token
        access_token_payload = {
            "user_id": user["id"],
            "email": user["email"],
            "role": user["role"],
            "exp": datetime.datetime.utcnow() + datetime.timedelta(
                seconds=int(os.getenv('JWT_ACCESS_TOKEN_EXPIRES', 3600))
            )
        }
        
        new_access_token = jwt.encode(
            access_token_payload,
            os.getenv('JWT_SECRET_KEY'),
            algorithm="HS256"
        )
        
        return jsonify({
            "success": True,
            "access_token": new_access_token
        })
        
    except jwt.ExpiredSignatureError:
        raise APIException("Refresh token has expired", 401)
    except jwt.InvalidTokenError:
        raise APIException("Invalid refresh token", 401)
    except Exception as e:
        current_app.logger.error(f"Token refresh error: {str(e)}")
        raise APIException("Token refresh failed", 500)

@auth.route("/logout", methods=["POST"])
def logout():
    """Logout endpoint (client should discard tokens)"""
    # In a production system, you might want to blacklist the token
    # For now, we'll just log the logout event
    
    token = None
    if 'Authorization' in request.headers:
        auth_header = request.headers['Authorization']
        try:
            token = auth_header.split(" ")[1]
            payload = jwt.decode(
                token,
                os.getenv('JWT_SECRET_KEY'),
                algorithms=['HS256']
            )
            user_id = payload.get('user_id')
            log_security_event("USER_LOGOUT", user_id=user_id, ip_address=request.remote_addr)
        except:
            pass  # Invalid token, but logout should still succeed
    
    return jsonify({
        "success": True,
        "message": "Logged out successfully"
    })

@auth.route("/user/theme", methods=["POST"])
@token_required
def save_user_theme():
    """Save user's theme preference"""
    try:
        data = request.get_json()
        user_id = request.current_user_id
        
        theme_id = data.get('theme_id')
        theme_name = data.get('theme_name')
        is_dark = data.get('is_dark', False)
        
        if not theme_id or not theme_name:
            raise APIException("Theme ID and name are required", 400)
        
        conn = get_connection()
        cursor = conn.cursor()
        
        # Update user's theme preference
        cursor.execute("""
            UPDATE users 
            SET theme_id = %s, theme_name = %s, is_dark_mode = %s, updated_at = CURRENT_TIMESTAMP
            WHERE id = %s
        """, (theme_id, theme_name, is_dark, user_id))
        
        conn.commit()
        cursor.close()
        conn.close()
        
        return jsonify({
            "success": True,
            "message": "Theme preference saved"
        })
        
    except APIException:
        raise
    except Exception as e:
        current_app.logger.error(f"Save theme error: {str(e)}")
        raise APIException("Failed to save theme preference", 500)

@auth.route("/user/theme", methods=["GET"])
@token_required
def get_user_theme():
    """Get user's theme preference"""
    try:
        user_id = request.current_user_id
        
        conn = get_connection()
        cursor = conn.cursor(dictionary=True)
        
        cursor.execute("""
            SELECT theme_id, theme_name, is_dark_mode
            FROM users 
            WHERE id = %s
        """, (user_id,))
        
        user = cursor.fetchone()
        cursor.close()
        conn.close()
        
        if user and user.get('theme_id'):
            return jsonify({
                "success": True,
                "theme": {
                    "theme_id": user['theme_id'],
                    "theme_name": user['theme_name'],
                    "is_dark": user.get('is_dark_mode', False)
                }
            })
        else:
            return jsonify({
                "success": True,
                "theme": None
            })
        
    except Exception as e:
        current_app.logger.error(f"Get theme error: {str(e)}")
        raise APIException("Failed to get theme preference", 500)
