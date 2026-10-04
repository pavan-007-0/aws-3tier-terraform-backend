from flask import Blueprint, request, jsonify
from db import get_connection
from functools import wraps
import jwt
import os

admin = Blueprint("admin", __name__)
SECRET_KEY = os.getenv("SECRET_KEY")

def admin_required(f):
    """Decorator to require admin authentication"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        token = request.headers.get('Authorization')
        if not token:
            return jsonify({"success": False, "message": "Token required"}), 401
        
        try:
            if token.startswith('Bearer '):
                token = token[7:]
            decoded = jwt.decode(token, SECRET_KEY, algorithms=['HS256'])
            if decoded.get('role') != 'admin':
                return jsonify({"success": False, "message": "Admin access required"}), 403
        except jwt.InvalidTokenError:
            return jsonify({"success": False, "message": "Invalid token"}), 401
        
        return f(*args, **kwargs)
    return decorated_function

# Product Management
@admin.route("/products", methods=["POST"])
@admin_required
def create_product():
    """Create a new product"""
    data = request.json
    required_fields = ['name', 'description', 'price']
    
    if not all(field in data for field in required_fields):
        return jsonify({"success": False, "message": "Missing required fields"}), 400
    
    conn = get_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
        INSERT INTO products (name, description, price, compare_price, sku, quantity, 
                            category_id, brand, status, featured)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    """, (
        data['name'], data['description'], data['price'], 
        data.get('compare_price'), data.get('sku'), data.get('quantity', 0),
        data.get('category_id'), data.get('brand'), 
        data.get('status', 'active'), data.get('featured', False)
    ))
    
    product_id = cursor.lastrowid
    conn.commit()
    cursor.close()
    conn.close()
    
    return jsonify({
        "success": True, 
        "message": "Product created successfully",
        "product_id": product_id
    }), 201

@admin.route("/products/<int:product_id>", methods=["PUT"])
@admin_required
def update_product(product_id):
    """Update an existing product"""
    data = request.json
    
    conn = get_connection()
    cursor = conn.cursor()
    
    # Build dynamic update query
    update_fields = []
    params = []
    
    updatable_fields = ['name', 'description', 'price', 'compare_price', 'sku', 
                       'quantity', 'category_id', 'brand', 'status', 'featured']
    
    for field in updatable_fields:
        if field in data:
            update_fields.append(f"{field} = %s")
            params.append(data[field])
    
    if not update_fields:
        return jsonify({"success": False, "message": "No fields to update"}), 400
    
    update_fields.append("updated_at = CURRENT_TIMESTAMP")
    params.append(product_id)
    
    cursor.execute(f"""
        UPDATE products 
        SET {', '.join(update_fields)}
        WHERE id = %s
    """, params)
    
    if cursor.rowcount == 0:
        return jsonify({"success": False, "message": "Product not found"}), 404
    
    conn.commit()
    cursor.close()
    conn.close()
    
    return jsonify({"success": True, "message": "Product updated successfully"})

@admin.route("/products/<int:product_id>", methods=["DELETE"])
@admin_required
def delete_product(product_id):
    """Soft delete a product"""
    conn = get_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
        UPDATE products 
        SET status = 'archived', updated_at = CURRENT_TIMESTAMP
        WHERE id = %s
    """, (product_id,))
    
    if cursor.rowcount == 0:
        return jsonify({"success": False, "message": "Product not found"}), 404
    
    conn.commit()
    cursor.close()
    conn.close()
    
    return jsonify({"success": True, "message": "Product archived successfully"})

# Category Management
@admin.route("/categories", methods=["POST"])
@admin_required
def create_category():
    """Create a new category"""
    data = request.json
    
    if not data.get('name'):
        return jsonify({"success": False, "message": "Category name required"}), 400
    
    conn = get_connection()
    cursor = conn.cursor()
    
    cursor.execute("""
        INSERT INTO categories (name, description, image)
        VALUES (%s, %s, %s)
    """, (data['name'], data.get('description'), data.get('image')))
    
    category_id = cursor.lastrowid
    conn.commit()
    cursor.close()
    conn.close()
    
    return jsonify({
        "success": True,
        "message": "Category created successfully",
        "category_id": category_id
    }), 201

@admin.route("/categories", methods=["GET"])
def get_categories():
    """Get all categories"""
    conn = get_connection()
    cursor = conn.cursor(dictionary=True)
    
    cursor.execute("""
        SELECT c.*, COUNT(p.id) as product_count
        FROM categories c
        LEFT JOIN products p ON c.id = p.category_id AND p.status = 'active'
        WHERE c.is_active = TRUE
        GROUP BY c.id
        ORDER BY c.name
    """)
    
    categories = cursor.fetchall()
    cursor.close()
    conn.close()
    
    return jsonify({"success": True, "categories": categories})

# Dashboard Analytics
@admin.route("/dashboard", methods=["GET"])
@admin_required
def get_dashboard_stats():
    """Get dashboard statistics"""
    conn = get_connection()
    cursor = conn.cursor(dictionary=True)
    
    # Total orders
    cursor.execute("SELECT COUNT(*) as total_orders FROM orders")
    total_orders = cursor.fetchone()['total_orders']
    
    # Total revenue
    cursor.execute("SELECT COALESCE(SUM(total_amount), 0) as total_revenue FROM orders WHERE payment_status = 'paid'")
    total_revenue = cursor.fetchone()['total_revenue']
    
    # Total products
    cursor.execute("SELECT COUNT(*) as total_products FROM products WHERE status = 'active'")
    total_products = cursor.fetchone()['total_products']
    
    # Total customers
    cursor.execute("SELECT COUNT(*) as total_customers FROM users WHERE role = 'customer'")
    total_customers = cursor.fetchone()['total_customers']
    
    # Recent orders
    cursor.execute("""
        SELECT o.id, o.order_number, o.total_amount, o.status, o.created_at,
               u.name as customer_name
        FROM orders o
        JOIN users u ON o.user_id = u.id
        ORDER BY o.created_at DESC
        LIMIT 10
    """)
    recent_orders = cursor.fetchall()
    
    # Low stock products
    cursor.execute("""
        SELECT id, name, quantity, sku
        FROM products
        WHERE quantity <= 10 AND status = 'active' AND track_quantity = TRUE
        ORDER BY quantity ASC
        LIMIT 10
    """)
    low_stock = cursor.fetchall()
    
    cursor.close()
    conn.close()
    
    return jsonify({
        "success": True,
        "stats": {
            "total_orders": total_orders,
            "total_revenue": float(total_revenue),
            "total_products": total_products,
            "total_customers": total_customers
        },
        "recent_orders": recent_orders,
        "low_stock_products": low_stock
    })

# Order Management
@admin.route("/orders", methods=["GET"])
@admin_required
def get_all_orders():
    """Get all orders with pagination"""
    page = int(request.args.get('page', 1))
    per_page = int(request.args.get('per_page', 20))
    status = request.args.get('status')
    
    offset = (page - 1) * per_page
    
    conn = get_connection()
    cursor = conn.cursor(dictionary=True)
    
    # Build query with optional status filter
    where_clause = ""
    params = []
    if status:
        where_clause = "WHERE o.status = %s"
        params.append(status)
    
    cursor.execute(f"""
        SELECT o.id, o.order_number, o.status, o.payment_status, o.total_amount, 
               o.created_at, u.name as customer_name, u.email as customer_email
        FROM orders o
        JOIN users u ON o.user_id = u.id
        {where_clause}
        ORDER BY o.created_at DESC
        LIMIT %s OFFSET %s
    """, params + [per_page, offset])
    
    orders = cursor.fetchall()
    
    # Get total count
    cursor.execute(f"SELECT COUNT(*) as total FROM orders o {where_clause}", params)
    total = cursor.fetchone()['total']
    
    cursor.close()
    conn.close()
    
    return jsonify({
        "success": True,
        "orders": orders,
        "pagination": {
            "page": page,
            "per_page": per_page,
            "total": total,
            "pages": (total + per_page - 1) // per_page
        }
    })