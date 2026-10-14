"""Unit tests for associate retry / verify helpers (no live AWS)."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "devops-agent-add-source.py"


def _load():
    spec = importlib.util.spec_from_file_location("devops_agent_add_source", SCRIPT)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


mod = _load()


def _client_error(code: str, message: str) -> ClientError:
    return ClientError(
        {"Error": {"Code": code, "Message": message}},
        "AssociateService",
    )


class RetryHelpersTest(unittest.TestCase):
    def test_passrole_denied_detected(self) -> None:
        exc = _client_error(
            "AccessDeniedException",
            "User is not authorized to perform: iam:PassRole",
        )
        self.assertTrue(mod._is_passrole_denied(exc))
        self.assertFalse(mod._is_retryable_associate_error(exc))

    def test_access_denied_without_passrole_not_retryable(self) -> None:
        exc = _client_error("AccessDeniedException", "aidevops:AssociateService denied")
        self.assertFalse(mod._is_passrole_denied(exc))
        self.assertFalse(mod._is_retryable_associate_error(exc))

    def test_invalid_request_not_retryable_by_default(self) -> None:
        exc = _client_error("InvalidRequestException", "bad configuration")
        self.assertFalse(mod._is_retryable_associate_error(exc))

    def test_propagation_message_is_retryable(self) -> None:
        exc = _client_error(
            "InvalidRequestException",
            "Role is not ready to be assumed yet",
        )
        self.assertTrue(mod._is_retryable_associate_error(exc))

    def test_throttling_is_retryable(self) -> None:
        exc = _client_error("ThrottlingException", "Rate exceeded")
        self.assertTrue(mod._is_retryable_associate_error(exc))


class AssociateSourceRetryTest(unittest.TestCase):
    def test_passrole_fails_fast_without_sleep(self) -> None:
        devops = MagicMock()
        devops.associate_service.side_effect = _client_error(
            "AccessDeniedException",
            "not authorized to perform: iam:PassRole on resource",
        )
        with (
            patch.object(mod.time, "sleep") as sleep,
            self.assertRaises(ClientError) as ctx,
        ):
            mod.associate_source(
                devops=devops,
                space_id="space-1",
                account_id="111122223333",
                role_arn="arn:aws:iam::111122223333:role/DevOpsAgentCrossAccountRole",
                external_id=None,
                region="us-east-1",
                profile="primary",
                dry_run=False,
                retry_on_iam_propagation=True,
            )
        sleep.assert_not_called()
        self.assertEqual(devops.associate_service.call_count, 1)
        self.assertIn("iam:PassRole", str(ctx.exception))

    def test_retries_on_propagation_then_succeeds(self) -> None:
        devops = MagicMock()
        devops.associate_service.side_effect = [
            _client_error(
                "InvalidRequestException",
                "Unable to assume role; not ready",
            ),
            {
                "association": {
                    "associationId": "a-1",
                    "status": "ACTIVE",
                }
            },
        ]
        with patch.object(mod.time, "sleep") as sleep:
            result = mod.associate_source(
                devops=devops,
                space_id="space-1",
                account_id="111122223333",
                role_arn="arn:aws:iam::111122223333:role/DevOpsAgentCrossAccountRole",
                external_id=None,
                region="us-east-1",
                profile="primary",
                dry_run=False,
                retry_on_iam_propagation=True,
            )
        self.assertEqual(result, ("a-1", "ACTIVE"))
        self.assertEqual(devops.associate_service.call_count, 2)
        sleep.assert_called_once()


class VerifyAssociationsTest(unittest.TestCase):
    def test_prior_missing_fails_immediately(self) -> None:
        devops = MagicMock()
        with (
            patch.object(
                mod,
                "list_associated_account_ids",
                return_value={"222233334444"},
            ),
            patch.object(mod.time, "sleep") as sleep,
            self.assertRaises(SystemExit) as ctx,
        ):
            mod.verify_prior_associations_retained(
                devops=devops,
                space_id="space-1",
                prior={"111122223333"},
                just_added="222233334444",
            )
        self.assertEqual(ctx.exception.code, 2)
        sleep.assert_not_called()

    def test_polls_until_just_added_appears(self) -> None:
        lists = [
            {"111122223333"},
            {"111122223333"},
            {"111122223333", "222233334444"},
        ]
        with (
            patch.object(mod, "list_associated_account_ids", side_effect=lists),
            patch.object(mod.time, "sleep") as sleep,
        ):
            mod.verify_prior_associations_retained(
                devops=MagicMock(),
                space_id="space-1",
                prior={"111122223333"},
                just_added="222233334444",
            )
        self.assertEqual(sleep.call_count, 2)


class HelpAndUsageTest(unittest.TestCase):
    def test_help_exits_0_and_hides_advanced(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            mod.parse_args(["--help"])
        self.assertEqual(ctx.exception.code, 0)

    def test_short_aliases_still_work(self) -> None:
        args = mod.parse_args(
            [
                "-s",
                "space-1",
                "-p",
                "primary",
                "--region",
                "us-east-1",
                "--dry-run",
                "111122223333",
            ]
        )
        self.assertEqual(args.agent_space_id, "space-1")
        self.assertEqual(args.profile, "primary")
        self.assertEqual(args.role_name, mod.DEFAULT_ROLE_NAME)


if __name__ == "__main__":
    unittest.main()
