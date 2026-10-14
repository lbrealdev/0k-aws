"""Unit tests for add-secondary-source helpers (mocked boto3; no live AWS)."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock, patch

from botocore.exceptions import ClientError

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "add-secondary-source.py"


def _load():
    spec = importlib.util.spec_from_file_location("add_secondary_source", SCRIPT)
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
    def test_passrole_denied_not_retryable(self) -> None:
        exc = _client_error(
            "AccessDeniedException",
            "User is not authorized to perform: iam:PassRole",
        )
        self.assertTrue(mod._is_passrole_denied(exc))
        self.assertFalse(mod._is_retryable_associate_error(exc))

    def test_access_denied_without_passrole_not_retryable(self) -> None:
        exc = _client_error("AccessDeniedException", "AssociateService denied")
        self.assertFalse(mod._is_passrole_denied(exc))
        self.assertFalse(mod._is_retryable_associate_error(exc))

    def test_propagation_message_is_retryable(self) -> None:
        exc = _client_error(
            "InvalidRequestException",
            "Role is not ready to be assumed yet",
        )
        self.assertTrue(mod._is_retryable_associate_error(exc))


class AssociateSourceRetryTest(unittest.TestCase):
    def test_passrole_fails_fast(self) -> None:
        client = MagicMock()
        client.associate_service.side_effect = _client_error(
            "AccessDeniedException",
            "not authorized to perform: iam:PassRole on resource",
        )
        with (
            patch.object(mod.time, "sleep") as sleep,
            self.assertRaises(ClientError) as ctx,
        ):
            mod.associate_source(
                client=client,
                setup_id="setup-1",
                account_id="111122223333",
                role_arn="arn:aws:iam::111122223333:role/Role",
                external_id=None,
                region="us-east-1",
                profile="source",
                dry_run=False,
                retry_on_iam_propagation=True,
            )
        sleep.assert_not_called()
        self.assertEqual(client.associate_service.call_count, 1)
        self.assertIn("iam:PassRole", str(ctx.exception))


class VerifyRoleTest(unittest.TestCase):
    def test_missing_role(self) -> None:
        iam = MagicMock()
        iam.get_role.side_effect = _client_error("NoSuchEntity", "not found")
        err = io.StringIO()
        with (
            redirect_stderr(err),
            self.assertRaises(SystemExit) as ctx,
        ):
            mod.verify_target_role(
                iam=iam,
                account_id="111122223333",
                role_name="Role",
                expected_trust={"Version": "2012-10-17", "Statement": []},
            )
        self.assertEqual(ctx.exception.code, 2)
        self.assertIn("missing IAM role", err.getvalue())

    def test_trust_mismatch(self) -> None:
        iam = MagicMock()
        iam.get_role.return_value = {
            "Role": {
                "Arn": "arn:aws:iam::111122223333:role/Role",
                "AssumeRolePolicyDocument": {"Version": "2012-10-17", "Statement": []},
            }
        }
        expected = mod.expected_trust_document("999988887777", "us-east-1", "setup-1")
        with self.assertRaises(SystemExit) as ctx:
            mod.verify_target_role(
                iam=iam,
                account_id="111122223333",
                role_name="Role",
                expected_trust=expected,
            )
        self.assertEqual(ctx.exception.code, 2)

    def test_missing_managed_policy(self) -> None:
        expected = mod.expected_trust_document("999988887777", "us-east-1", "setup-1")
        iam = MagicMock()
        iam.get_role.return_value = {
            "Role": {
                "Arn": "arn:aws:iam::111122223333:role/Role",
                "AssumeRolePolicyDocument": expected,
            }
        }
        iam.list_attached_role_policies.return_value = {"AttachedPolicies": []}
        with self.assertRaises(SystemExit) as ctx:
            mod.verify_target_role(
                iam=iam,
                account_id="111122223333",
                role_name="Role",
                expected_trust=expected,
            )
        self.assertEqual(ctx.exception.code, 2)

    def test_ok(self) -> None:
        expected = mod.expected_trust_document("999988887777", "us-east-1", "setup-1")
        iam = MagicMock()
        iam.get_role.return_value = {
            "Role": {
                "Arn": "arn:aws:iam::111122223333:role/Role",
                "AssumeRolePolicyDocument": expected,
            }
        }
        iam.list_attached_role_policies.return_value = {
            "AttachedPolicies": [{"PolicyArn": mod.AWS_API_MANAGED_POLICY_ARN}]
        }
        arn = mod.verify_target_role(
            iam=iam,
            account_id="111122223333",
            role_name="Role",
            expected_trust=expected,
        )
        self.assertEqual(arn, "arn:aws:iam::111122223333:role/Role")


class VerifyAssociationsTest(unittest.TestCase):
    def test_prior_missing_fails_immediately(self) -> None:
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
                client=MagicMock(),
                setup_id="setup-1",
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
                client=MagicMock(),
                setup_id="setup-1",
                prior={"111122223333"},
                just_added="222233334444",
            )
        self.assertEqual(sleep.call_count, 2)


class DryRunMainTest(unittest.TestCase):
    def test_dry_run_prints_commands_no_associate(self) -> None:
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
        expected = mod.expected_trust_document(
            "999988887777", "us-east-1", "setup-1"
        )
        iam = MagicMock()
        iam.get_role.return_value = {
            "Role": {
                "Arn": "arn:aws:iam::111122223333:role/"
                + mod.AWS_API_DEFAULT_ROLE_NAME,
                "AssumeRolePolicyDocument": expected,
            }
        }
        iam.list_attached_role_policies.return_value = {
            "AttachedPolicies": [{"PolicyArn": mod.AWS_API_MANAGED_POLICY_ARN}]
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
                    "--setup-id",
                    "setup-1",
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
        self.assertIn("dry run: nothing changed", err.getvalue())


class ParseArgsTest(unittest.TestCase):
    def test_help_exits_0(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            mod.parse_args(["--help"])
        self.assertEqual(ctx.exception.code, 0)

    def test_requires_target_profile(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            mod.parse_args(
                [
                    "--setup-id",
                    "s",
                    "--source-profile",
                    "src",
                    "--region",
                    "us-east-1",
                ]
            )
        self.assertEqual(ctx.exception.code, 1)


class TrustDocumentTest(unittest.TestCase):
    def test_canonical_roundtrip(self) -> None:
        doc = mod.expected_trust_document("111122223333", "us-east-1", "setup-1")
        again = json.loads(json.dumps(doc))
        self.assertEqual(mod.canonical_json(doc), mod.canonical_json(again))
        self.assertIn(mod.AWS_API_SERVICE_PRINCIPAL, json.dumps(doc))


if __name__ == "__main__":
    unittest.main()
