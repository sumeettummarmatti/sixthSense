from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.contacts import models as contact_models  # noqa: F401  (registers models)
from app.core import audit  # noqa: F401
from app.core.config import get_settings
from app.core.db import Base
from app.escalation import models as escalation_models  # noqa: F401
from app.escort import models as escort_models  # noqa: F401
from app.feedback import models as feedback_models  # noqa: F401
from app.identity import models  # noqa: F401
from app.journey import models as journey_models  # noqa: F401
from app.matching import models as matching_models  # noqa: F401
from app.moderation import models as moderation_models  # noqa: F401
from app.notification import models as notification_models  # noqa: F401
from app.profiles import models as profile_models  # noqa: F401
from app.verification import models as verification_models  # noqa: F401
from app.walks import models as walk_models  # noqa: F401

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

config.set_main_option("sqlalchemy.url", get_settings().core_database_url)
target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
