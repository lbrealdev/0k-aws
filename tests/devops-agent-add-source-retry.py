"""Unit tests for devops-agent-add-source (mocked boto3; no live AWS)."""

from __future__ import annotations

import importlib.util
import io
import os
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock, patch

from botocore.exceptions import ClientError, TokenRetrievalError

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


class StatusUITest(unittest.TestCase):
    def test_no_color_when_stream_not_tty(self) -> None:
        buf = io.StringIO()
        ui = mod.StatusUI(stream=buf)
        self.assertFalse(ui.color)
        ui.ok("role", "111122223333")
        out = buf.getvalue()
        self.assertIn("[ok]", out)
        self.assertNotIn("\033[", out)

    def test_color_when_forced_tty(self) -> None:
        class TTY(io.StringIO):
            def isatty(self) -> bool:
                return True

        tty = TTY()
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("NO_COLOR", None)
            ui = mod.StatusUI(stream=tty)
            self.assertTrue(ui.color)
            ui.ok("source", "acct")
        self.assertIn("\033[", tty.getvalue())

    def test_status_and_summary_on_stderr_stream(self) -> None:
        buf = io.StringIO()
        ui = mod.StatusUI(stream=buf)
        ui.header("hdr")
        ui.ok("source", "acct")
        ui.summary(1, 2, 0)
        text = buf.getvalue()
        self.assertIn("hdr", text)
        self.assertIn("[ok]", text)
        self.assertIn("summary", text)
        self.assertIn("associated=1", text)
        self.assertIn("skipped=2", text)


class RetryHelpersTest(unittest.TestCase):
    def test_passrole_denied_not_retryable(self) -> None:
        exc = _client_error(
            "AccessDeniedException",
            "User is not authorized to perform: iam:PassRole",
        )
        self.assertTrue(mod._is_passrole_denied(exc))
        self.assertFalse(mod._is_retryable_associate_error(exc))

    def test_propagation_message_is_retryable(self) -> None:
        exc = _client_error(
            "InvalidRequestException",
            "Role is not ready to be assumed yet",
        )
        self.assertTrue(mod._is_retryable_associate_error(exc))


class AssociateSourceRetryTest(unittest.TestCase):
    def test_passrole_fails_fast(self) -> None:
        devops = MagicMock()
        devops.associate_service.side_effect = _client_error(
            "AccessDeniedException",
            "not authorized to perform: iam:PassRole on resource",
        )
        ui = mod.StatusUI(stream=io.StringIO())
        with (
            patch.object(mod.time, "sleep") as sleep,
            self.assertRaises(mod.VerificationError) as ctx,
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
                ui=ui,
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
        ui = mod.StatusUI(stream=io.StringIO())
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
                ui=ui,
            )
        self.assertEqual(result, ("a-1", "ACTIVE"))
        self.assertEqual(devops.associate_service.call_count, 2)
        sleep.assert_called_once()


class VerifyAssociationsTest(unittest.TestCase):
    def test_prior_missing_fails_immediately(self) -> None:
        ui = mod.StatusUI(stream=io.StringIO())
        with (
            patch.object(
                mod,
                "list_associated_account_ids",
                return_value={"222233334444"},
            ),
            patch.object(mod.time, "sleep") as sleep,
            self.assertRaises(mod.VerificationError),
        ):
            mod.verify_prior_associations_retained(
                devops=MagicMock(),
                space_id="space-1",
                prior={"111122223333"},
                just_added="222233334444",
                ui=ui,
            )
        sleep.assert_not_called()

    def test_polls_until_just_added_appears(self) -> None:
        lists = [
            {"111122223333"},
            {"111122223333"},
            {"111122223333", "222233334444"},
        ]
        ui = mod.StatusUI(stream=io.StringIO())
        with (
            patch.object(mod, "list_associated_account_ids", side_effect=lists),
            patch.object(mod.time, "sleep") as sleep,
        ):
            mod.verify_prior_associations_retained(
                devops=MagicMock(),
                space_id="space-1",
                prior={"111122223333"},
                just_added="222233334444",
                ui=ui,
            )
        self.assertEqual(sleep.call_count, 2)


class SSOResolveTest(unittest.TestCase):
    def test_token_retrieval_error_asks_for_sso_login(self) -> None:
        session = MagicMock()
        session.client.return_value.get_caller_identity.side_effect = (
            TokenRetrievalError(
                error_msg="Token has expired and refresh failed",
                provider="sso",
            )
        )
        with self.assertRaises(mod.VerificationError) as ctx:
            mod.resolve_account_id(session, "my-sso-profile")
        msg = str(ctx.exception)
        self.assertIn("aws sso login --profile my-sso-profile", msg)
        self.assertIn("SSO token", msg)


class DryRunMainTest(unittest.TestCase):
    def test_dry_run_stdout_plan_stderr_status(self) -> None:
        source_session = MagicMock()
        target_session = MagicMock()
        source_sts = MagicMock()
        source_sts.get_caller_identity.return_value = {"Account": "999988887777"}
        target_sts = MagicMock()
        target_sts.get_caller_identity.return_value = {"Account": "111122223333"}
        client = MagicMock()
        client.list_associations.return_value = {"associations": []}
        source_session.client.side_effect = lambda name, **kw: (
            source_sts if name == "sts" else client
        )
        expected = mod.trust_document("999988887777", "us-east-1", "space-1")
        iam = MagicMock()
        iam.get_role.return_value = {
            "Role": {
                "Arn": "arn:aws:iam::111122223333:role/" + mod.DEFAULT_ROLE_NAME,
                "AssumeRolePolicyDocument": expected,
            }
        }
        iam.list_attached_role_policies.return_value = {
            "AttachedPolicies": [{"PolicyArn": mod.MANAGED_POLICY_ARN}]
        }

        def target_client(name, **kw):
            if name == "sts":
                return target_sts
            if name == "iam":
                return iam
            raise AssertionError(name)

        target_session.client.side_effect = target_client

        def session_for(profile, region=None):
            if profile == "source":
                return source_session
            if profile == "target":
                return target_session
            raise AssertionError(profile)

        out = io.StringIO()
        err = io.StringIO()
        with (
            patch.object(mod, "session_for_profile", side_effect=session_for),
            redirect_stdout(out),
            redirect_stderr(err),
        ):
            code = mod.main(
                [
                    "--agent-space-id",
                    "space-1",
                    "--source-profile",
                    "source",
                    "--region",
                    "us-east-1",
                    "--target-profile",
                    "target",
                    "--dry-run",
                ]
            )
        self.assertEqual(code, 0)
        client.associate_service.assert_not_called()
        printed = out.getvalue()
        self.assertIn("associate-service", printed)
        self.assertIn("list-associations", printed)
        self.assertNotIn("[ok]", printed)
        self.assertNotIn("[dry-run]", printed)
        status = err.getvalue()
        self.assertIn("[ok]", status)
        self.assertIn("[dry-run]", status)
        self.assertIn("summary", status)
        self.assertIn("associated=1", status)
        self.assertNotIn("\033[", status)


class ParseArgsTest(unittest.TestCase):
    def test_help_exits_0_and_shows_groups(self) -> None:
        out = io.StringIO()
        with redirect_stdout(out), self.assertRaises(SystemExit) as ctx:
            mod.parse_args(["--help"])
        self.assertEqual(ctx.exception.code, 0)
        text = out.getvalue()
        self.assertIn("-h, --help", text)
        self.assertIn("--source-profile", text)
        self.assertIn("--target-profile", text)
        self.assertIn("required:", text)
        self.assertIn("optional:", text)
        self.assertNotIn("Advanced", text)
        self.assertEqual(text.count("\noptions:"), 0)

    def test_h_exits_0(self) -> None:
        with redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as ctx:
            mod.parse_args(["-h"])
        self.assertEqual(ctx.exception.code, 0)

    def test_missing_target_exits_1(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            mod.parse_args(
                [
                    "--agent-space-id",
                    "s",
                    "--source-profile",
                    "src",
                    "--region",
                    "us-east-1",
                ]
            )
        self.assertEqual(ctx.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
