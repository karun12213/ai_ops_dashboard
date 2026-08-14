import unittest
from decimal import Decimal

from pydantic import ValidationError

from backend.utils.config import Settings


class JwtSecretProductionGuardTests(unittest.TestCase):
    production_database_url = "postgresql+asyncpg://app@db:5432/app"
    production_secret = "x" * 48

    def test_documented_placeholder_jwt_secrets_are_rejected_in_production(self) -> None:
        placeholders = (
            "change-this-development-secret-to-at-least-32-chars",
            "local-development-secret-change-before-production",
            "replace-with-a-long-random-secret-at-least-32-characters",
            "your-secret-value-that-is-definitely-long-enough",
        )
        for placeholder in placeholders:
            with self.subTest(placeholder=placeholder), self.assertRaises(ValidationError):
                Settings(
                    _env_file=None,
                    app_env="production",
                    database_url=self.production_database_url,
                    jwt_secret_key=placeholder,
                )

    def test_overridden_jwt_secret_accepted_in_production(self) -> None:
        settings = Settings(
            _env_file=None,
            app_env="production",
            database_url=self.production_database_url,
            jwt_secret_key=self.production_secret,
        )
        self.assertEqual(settings.app_env, "production")

    def test_development_uses_an_ephemeral_jwt_secret_when_unconfigured(self) -> None:
        first = Settings(_env_file=None, app_env="development")
        second = Settings(_env_file=None, app_env="development")

        self.assertGreaterEqual(len(first.jwt_secret_key), 32)
        self.assertNotEqual(first.jwt_secret_key, second.jwt_secret_key)

    def test_production_requires_an_explicit_jwt_secret(self) -> None:
        with self.assertRaises(ValidationError):
            Settings(
                _env_file=None,
                app_env="production",
                database_url=self.production_database_url,
            )


class ProductionEnvironmentGuardTests(unittest.TestCase):
    production_secret = "x" * 48
    production_database_url = "postgresql+asyncpg://app@db:5432/app"

    def test_sqlite_is_rejected_in_production(self) -> None:
        with self.assertRaises(ValidationError):
            Settings(
                _env_file=None,
                app_env="production",
                database_url="sqlite+aiosqlite:///./backend/restaurant_ops.db",
                jwt_secret_key=self.production_secret,
            )

    def test_auto_create_tables_is_rejected_in_production(self) -> None:
        with self.assertRaises(ValidationError):
            Settings(
                _env_file=None,
                app_env="production",
                database_url=self.production_database_url,
                jwt_secret_key=self.production_secret,
                auto_create_tables=True,
            )

    def test_production_defaults_disable_docs_and_table_creation(self) -> None:
        settings = Settings(
            _env_file=None,
            app_env="production",
            database_url=self.production_database_url,
            jwt_secret_key=self.production_secret,
        )
        self.assertFalse(settings.should_enable_docs)
        self.assertFalse(settings.should_auto_create_tables)

    def test_development_defaults_keep_docs_and_table_creation_enabled(self) -> None:
        settings = Settings(_env_file=None, app_env="development")
        self.assertTrue(settings.should_enable_docs)
        self.assertTrue(settings.should_auto_create_tables)


class ProviderPricingSettingsTests(unittest.TestCase):
    def test_default_provider_rates_match_configured_gpt4o_and_sarvam_rates(self) -> None:
        settings = Settings(_env_file=None, app_env="development")

        self.assertEqual(settings.sarvam_cost_per_audio_hour_inr, Decimal("30.00"))
        self.assertEqual(settings.openai_input_cost_per_million_usd, Decimal("2.50"))
        self.assertEqual(
            settings.openai_cached_input_cost_per_million_usd,
            Decimal("1.25"),
        )
        self.assertEqual(settings.openai_output_cost_per_million_usd, Decimal("10.00"))


if __name__ == "__main__":
    unittest.main()
