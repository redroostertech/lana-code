from flask import Flask
from config import config_by_name


def create_app(config_name="development"):
    """Application factory pattern."""
    app = Flask(__name__)
    app.config.from_object(config_by_name[config_name])

    from app.routes import main_bp

    app.register_blueprint(main_bp)

    return app
