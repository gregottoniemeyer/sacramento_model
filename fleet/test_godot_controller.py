import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from fleet import godot_controller as controller


def completed(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(["test"], returncode, stdout, stderr)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.original_operator = controller.CURRENT_OPERATOR
        self.original_locality = {
            target: computer["local"]
            for target, computer in controller.COMPUTERS.items()
        }
        self.original_project_source = controller.PROJECT_SOURCE_DIR
        self.original_fleet_source = controller.FLEET_SOURCE_DIR

    def tearDown(self):
        controller.CURRENT_OPERATOR = self.original_operator
        controller.PROJECT_SOURCE_DIR = self.original_project_source
        controller.FLEET_SOURCE_DIR = self.original_fleet_source
        for target, local in self.original_locality.items():
            controller.COMPUTERS[target]["local"] = local

    def configure_studio(self):
        return controller.configure_operator(
            "en0: flags\n\tinet 196.168.50.51 netmask 0xffffff00\n"
            "\tinet 10.43.214.159 netmask 0xffffff00\n"
        )

    def test_operator_detection_is_strict_and_safe(self):
        studio = self.configure_studio()
        self.assertEqual("studio", studio["name"])
        self.assertFalse(any(computer["local"] for computer in controller.COMPUTERS.values()))

        governator = controller.configure_operator(
            "en0: flags\n\tinet 196.168.50.11 netmask 0xffffff00\n"
        )
        self.assertEqual("governator", governator["name"])
        self.assertTrue(controller.COMPUTERS["11"]["local"])
        self.assertFalse(controller.COMPUTERS["21"]["local"])

        with self.assertRaisesRegex(ValueError, "requires exactly one operator address"):
            controller.configure_operator(
                "en0: flags\n\tinet 192.168.50.51 netmask 0xffffff00\n"
            )
        with self.assertRaisesRegex(ValueError, "requires exactly one operator address"):
            controller.configure_operator(
                "\tinet 196.168.50.11 netmask 0xffffff00\n"
                "\tinet 196.168.50.51 netmask 0xffffff00\n"
            )

    def test_ssh_uses_dedicated_identity_and_noninteractive_options(self):
        self.configure_studio()
        with mock.patch.object(controller, "run_local", return_value=completed()) as run:
            controller.ssh(controller.COMPUTERS["11"], "true")
        command = run.call_args.args[0]
        self.assertEqual("ssh", command[0])
        self.assertIn("BatchMode=yes", command)
        self.assertIn("IdentitiesOnly=yes", command)
        self.assertIn("StrictHostKeyChecking=yes", command)
        self.assertIn("-i", command)
        identity_index = command.index("-i") + 1
        self.assertTrue(command[identity_index].endswith("water_council_fleet_ed25519"))
        self.assertIn("francescospagnolo@196.168.50.11", command)

    def test_studio_stop_for_11_is_remote_and_never_local_pkill(self):
        self.configure_studio()
        with mock.patch.object(controller, "ssh", return_value=completed()) as remote:
            with mock.patch.object(controller, "run_local") as local:
                result = controller.stop_godot_processes(controller.COMPUTERS["11"])
        self.assertEqual(0, result.returncode)
        remote.assert_called_once()
        self.assertIn("pkill -TERM", remote.call_args.args[1])
        local.assert_not_called()

    def test_central_state_reads_and_writes_on_11_over_ssh_from_studio(self):
        self.configure_studio()
        state_json = (
            '{"active_regime_ids":["kinship"],'
            '"debug_geometry_visible":false}\n'
        )
        with mock.patch.object(
            controller,
            "ssh",
            side_effect=[completed(stdout=state_json), completed()],
        ) as remote:
            regimes, geometry = controller.load_controller_state()
            controller.save_controller_state(["kinship"], False)
        self.assertEqual({"kinship"}, regimes)
        self.assertFalse(geometry)
        self.assertEqual(2, remote.call_count)
        self.assertIn(controller.REGIME_STATE_PATH, remote.call_args_list[0].args[1])
        write_command = remote.call_args_list[1].args[1]
        self.assertIn("umask 077", write_command)
        self.assertIn("mv", write_command)

    def test_required_central_state_refuses_missing_file(self):
        self.configure_studio()
        with mock.patch.object(controller, "_read_controller_state_text", return_value=None):
            with self.assertRaisesRegex(ValueError, "does not exist"):
                controller.load_controller_state(require_exists=True)
        with mock.patch.object(controller, "_read_controller_state_text", return_value=None):
            self.assertEqual((set(), None), controller.load_controller_state())

    def test_backup_cleanup_accepts_only_exact_generated_path(self):
        self.configure_studio()
        valid = (
            "/Users/francescospagnolo/Documents/watercouncil/"
            ".code.backup-0123456789ab"
        )
        with mock.patch.object(controller, "ssh", return_value=completed()) as remote:
            ok, _message = controller._cleanup_backup("11", valid)
        self.assertTrue(ok)
        remote.assert_called_once()

        with mock.patch.object(controller, "ssh") as remote:
            ok, message = controller._cleanup_backup(
                "11",
                "/Users/francescospagnolo/Documents/watercouncil/.code.backup-anything",
            )
        self.assertFalse(ok)
        self.assertIn("refusing unsafe", message)
        remote.assert_not_called()

    def test_stage_cleanup_accepts_only_exact_generated_path(self):
        self.configure_studio()
        valid = (
            "/Users/francescospagnolo/Documents/watercouncil/"
            ".code.deploy-0123456789ab"
        )
        with mock.patch.object(controller, "ssh", return_value=completed()) as remote:
            ok, _message = controller._cleanup_stage("11", valid)
        self.assertTrue(ok)
        remote.assert_called_once()

        with mock.patch.object(controller, "ssh") as remote:
            ok, message = controller._cleanup_stage(
                "11",
                "/Users/francescospagnolo/Documents/watercouncil/.code.deploy-anything",
            )
        self.assertFalse(ok)
        self.assertIn("refusing unsafe", message)
        remote.assert_not_called()

    def test_remote_check_requires_class_and_font_caches(self):
        self.configure_studio()
        with mock.patch.object(controller, "ssh", return_value=completed()) as remote:
            ok, message = controller.check_computer(controller.COMPUTERS["11"])
        self.assertTrue(ok)
        self.assertIn("import cache", message)
        command = remote.call_args.args[1]
        self.assertIn(controller.CAFFEINATE_BIN, command)
        self.assertIn(controller.GLOBAL_CLASS_CACHE_RELATIVE_PATH, command)
        self.assertIn(controller.FONT_CACHE_RELATIVE_PATH, command)
        for class_name in controller.REQUIRED_GLOBAL_CLASSES:
            self.assertIn(f'"class": &"{class_name}"', command)

    def test_start_preflight_failure_never_stops_working_godot(self):
        self.configure_studio()
        with mock.patch.object(
            controller,
            "check_computer",
            return_value=(False, "project missing"),
        ):
            with mock.patch.object(controller, "stop_godot_processes") as stop:
                _ip, ok, message = controller.perform("11", "start")
        self.assertFalse(ok)
        self.assertIn("left running processes untouched", message)
        stop.assert_not_called()

    def test_process_pattern_matches_godot_child_but_not_caffeinate_parent(self):
        pattern = controller.all_godot_process_pattern()
        child = (
            f"{controller.GODOT_BIN} --path "
            "/Users/gregniemeyer/Documents/watercouncil/code"
        )
        parent = (
            f"{controller.CAFFEINATE_BIN} -d -i -s "
            f"{child}"
        )
        self.assertIsNotNone(controller.re.search(pattern, child))
        self.assertIsNone(controller.re.search(pattern, parent))

    def test_remote_start_and_editor_use_lifetime_caffeinate_guard(self):
        self.configure_studio()
        for action in ("start", "editor"):
            with self.subTest(action=action):
                with mock.patch.object(
                    controller,
                    "check_computer",
                    return_value=(True, "ready"),
                ):
                    with mock.patch.object(
                        controller,
                        "stop_godot_processes",
                        return_value=completed(),
                    ):
                        with mock.patch.object(
                            controller,
                            "ssh",
                            return_value=completed(),
                        ) as remote:
                            _ip, ok, _message = controller.perform("21", action)
                self.assertTrue(ok)
                launch = remote.call_args.args[1]
                expected_prefix = "nohup " + " ".join(
                    (
                        controller.CAFFEINATE_BIN,
                        *controller.CAFFEINATE_FLAGS,
                        controller.GODOT_BIN,
                    )
                )
                self.assertTrue(launch.startswith(expected_prefix), launch)
                if action == "start":
                    self.assertIn("-- --stages=1,2", launch)
                    self.assertNotIn("--editor", launch)
                else:
                    self.assertIn("--editor", launch)
                    self.assertNotIn("--stages=", launch)

    def test_local_start_uses_same_lifetime_caffeinate_guard(self):
        controller.configure_operator(
            "en0: flags\n\tinet 196.168.50.11 netmask 0xffffff00\n"
        )
        with mock.patch.object(
            controller,
            "check_computer",
            return_value=(True, "ready"),
        ):
            with mock.patch.object(
                controller,
                "stop_godot_processes",
                return_value=completed(),
            ):
                with mock.patch("builtins.open", mock.mock_open()):
                    with mock.patch.object(controller.subprocess, "Popen") as launch:
                        _ip, ok, _message = controller.perform("11", "start")
        self.assertTrue(ok)
        command = launch.call_args.args[0]
        self.assertEqual(controller.CAFFEINATE_BIN, command[0])
        self.assertEqual(list(controller.CAFFEINATE_FLAGS), command[1:4])
        self.assertEqual(controller.GODOT_BIN, command[4])
        self.assertEqual(["--", "--stages=7"], command[-2:])

    def test_status_requires_exact_project_and_stage_arguments(self):
        self.configure_studio()
        wrong_path = (
            "100 /Applications/Godot.app/Contents/MacOS/Godot "
            "--path /Users/gregniemeyer/Documents/watercouncil/code-old "
            "-- --stages=1,2\n"
        )
        wrong_stages = (
            "100 /Applications/Godot.app/Contents/MacOS/Godot "
            "--path /Users/gregniemeyer/Documents/watercouncil/code "
            "-- --stages=2,1\n"
        )
        correct = (
            "100 /Applications/Godot.app/Contents/MacOS/Godot "
            "--path /Users/gregniemeyer/Documents/watercouncil/code "
            "-- --stages=1,2\n"
        )
        for output in (wrong_path, wrong_stages):
            with mock.patch.object(controller, "ssh", return_value=completed(stdout=output)):
                ok, message = controller.all_godot_status(controller.COMPUTERS["21"])
            self.assertFalse(ok)
            self.assertIn("unexpected Godot process layout", message)
        with mock.patch.object(controller, "ssh", return_value=completed(stdout=correct)):
            ok, _message = controller.all_godot_status(controller.COMPUTERS["21"])
        self.assertTrue(ok)

    def test_status_rejects_extra_godot_processes(self):
        self.configure_studio()
        expected = (
            "100 /Applications/Godot.app/Contents/MacOS/Godot "
            "--path /Users/gregniemeyer/Documents/watercouncil/code\n"
        )
        extra = (
            "200 /Applications/Godot.app/Contents/MacOS/Godot "
            "--path /private/tmp/old-code\n"
        )
        with mock.patch.object(
            controller,
            "ssh",
            return_value=completed(stdout=expected + extra),
        ):
            _ip, ok, message = controller.perform("21", "status")
        self.assertFalse(ok)
        self.assertIn("unexpected Godot process layout", message)

    def test_duplicate_targets_are_rejected_before_threaded_action(self):
        self.configure_studio()
        argv = ["godot_controller.py", "start", "21", "21"]
        with mock.patch.object(sys, "argv", argv):
            with mock.patch.object(
                controller,
                "configure_operator",
                return_value={
                    "name": "studio",
                    "ip": "196.168.50.51",
                    "local_target": None,
                },
            ):
                with mock.patch.object(controller, "perform") as perform:
                    with self.assertRaises(SystemExit) as exit_context:
                        controller.main()
        self.assertEqual(2, exit_context.exception.code)
        perform.assert_not_called()

    def test_restart_dispatches_one_clean_start_not_stop_then_start(self):
        self.configure_studio()
        argv = ["godot_controller.py", "restart", "21"]
        with mock.patch.object(sys, "argv", argv):
            with mock.patch.object(
                controller,
                "configure_operator",
                return_value={
                    "name": "studio",
                    "ip": "196.168.50.51",
                    "local_target": None,
                },
            ):
                with mock.patch.object(
                    controller,
                    "load_controller_state",
                    return_value=(set(), None),
                ):
                    with mock.patch.object(
                        controller,
                        "perform",
                        return_value=("196.168.50.21", True, "started"),
                    ) as perform:
                        with mock.patch.object(
                            controller,
                            "send_fleet_regimes",
                            return_value=[("196.168.50.21", 20, 2)],
                        ):
                            with mock.patch("builtins.print"):
                                with self.assertRaises(SystemExit) as exit_context:
                                    controller.main()
        self.assertEqual(0, exit_context.exception.code)
        perform.assert_called_once_with("21", "start")

    def test_rsync_commands_exactly_cover_project_root_and_fleet_subtree(self):
        self.configure_studio()
        computer = controller.COMPUTERS["21"]
        source = Path("/source/project")
        project_command = controller._rsync_command(
            source,
            computer,
            computer["project"],
            verify=True,
            excludes=controller.PROJECT_DEPLOY_EXCLUDES,
        )
        self.assertIn("-rlcin", project_command)
        self.assertIn("--delete", project_command)
        self.assertIn("fleet/", project_command)
        self.assertTrue(project_command[-2].endswith("/"))
        self.assertTrue(project_command[-1].endswith("/code/"))
        fleet_command = controller._rsync_command(
            Path("/source/fleet"),
            computer,
            computer["project"] + "/fleet",
            verify=False,
            excludes=controller.FLEET_DEPLOY_EXCLUDES,
        )
        self.assertEqual("-a", fleet_command[1])
        self.assertTrue(fleet_command[-1].endswith("/code/fleet/"))

    def test_deploy_source_requires_project_and_fleet_tools(self):
        self.configure_studio()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project = root / "godot_experiments"
            fleet = root / "fleet"
            project.mkdir()
            fleet.mkdir()
            required = controller.required_project_files(
                {"stages": tuple(controller.STAGE_SCREEN_IDS)}
            )
            for relative_path in required:
                path = project / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("test\n", encoding="utf-8")
            for filename in ("godot_controller.py", "README.md", "test_godot_controller.py"):
                (fleet / filename).write_text("test\n", encoding="utf-8")
            controller.PROJECT_SOURCE_DIR = project
            controller.FLEET_SOURCE_DIR = fleet
            self.assertEqual(project.resolve(), controller.validate_deploy_source(["11"]))
            (fleet / "README.md").unlink()
            with self.assertRaisesRegex(ValueError, "fleet tools are incomplete"):
                controller.validate_deploy_source(["11"])

    def test_dry_run_distinguishes_difference_from_transport_error(self):
        self.configure_studio()
        with mock.patch.object(
            controller,
            "validate_deploy_source",
            return_value=Path("/source/project"),
        ):
            with mock.patch.object(os.path, "isfile", return_value=True):
                with mock.patch.object(
                    controller,
                    "_compare_tree",
                    return_value=(True, False, "tree differs"),
                ):
                    changed = controller.deploy_targets(["11"], dry_run=True)
                with mock.patch.object(
                    controller,
                    "_compare_tree",
                    return_value=(False, False, "connection timed out"),
                ):
                    failed = controller.deploy_targets(["11"], dry_run=True)
        self.assertTrue(changed[0][1])
        self.assertIn("changes required", changed[0][2])
        self.assertFalse(failed[0][1])
        self.assertIn("connection timed out", failed[0][2])

    def test_tree_comparison_ignores_only_rsync_metadata_notices(self):
        self.configure_studio()
        timestamp_only = completed(
            stdout=(
                ".f..T.... flow/assets/fonts/BarlowCondensed-Medium.ttf.import\n"
                ".f..T.... img/icon.svg.import\n"
            )
        )
        with mock.patch.object(
            controller,
            "_rsync_project",
            side_effect=[timestamp_only, completed()],
        ):
            compared, matches, message = controller._compare_tree(
                Path("/source/project"),
                controller.COMPUTERS["11"],
                controller.COMPUTERS["11"]["project"],
            )
        self.assertTrue(compared)
        self.assertTrue(matches)
        self.assertEqual("checksum match", message)

        substantive_outputs = (
            ">fc...... flow/gpu_stage/gpu_flow_stage_2d.gd\n",
            ">f+++++++ flow/data/new.txt\n",
            "cL++++++++ flow/link -> target\n",
            "*deleting   flow/retired.txt\n",
        )
        for substantive_output in substantive_outputs:
            with self.subTest(output=substantive_output.strip()):
                with mock.patch.object(
                    controller,
                    "_rsync_project",
                    side_effect=[completed(stdout=substantive_output), completed()],
                ):
                    compared, matches, message = controller._compare_tree(
                        Path("/source/project"),
                        controller.COMPUTERS["11"],
                        controller.COMPUTERS["11"]["project"],
                    )
                self.assertTrue(compared)
                self.assertFalse(matches)
                self.assertIn(substantive_output.strip(), message)

    def test_geometry_only_set_requires_existing_authoritative_state(self):
        self.configure_studio()
        argv = ["godot_controller.py", "set", "--geo", "FALSE"]
        with mock.patch.object(sys, "argv", argv):
            with mock.patch.object(
                controller,
                "configure_operator",
                return_value={
                    "name": "studio",
                    "ip": "196.168.50.51",
                    "local_target": None,
                },
            ):
                with mock.patch.object(
                    controller,
                    "load_controller_state",
                    side_effect=ValueError("does not exist"),
                ) as load:
                    with mock.patch.object(controller, "send_fleet_regimes") as send:
                        with self.assertRaises(SystemExit) as exit_context:
                            controller.main()
        self.assertEqual(2, exit_context.exception.code)
        load.assert_called_once_with(require_exists=True)
        send.assert_not_called()

    def test_deploy_rejects_duplicate_targets_defensively(self):
        self.configure_studio()
        results = controller.deploy_targets(["21", "21"], dry_run=True)
        self.assertFalse(results[0][1])
        self.assertIn("duplicate", results[0][2])

    def test_staging_failure_never_stops_or_promotes(self):
        self.configure_studio()
        with mock.patch.object(
            controller,
            "validate_deploy_source",
            return_value=Path("/source/project"),
        ):
            with mock.patch.object(os.path, "isfile", return_value=True):
                with mock.patch.object(
                    controller,
                    "_prepare_stage",
                    return_value=(False, "copy failed"),
                ):
                    with mock.patch.object(controller, "_cleanup_stage", return_value=(True, "clean")):
                        with mock.patch.object(controller, "stop_godot_processes") as stop:
                            with mock.patch.object(controller, "_promote_stage") as promote:
                                results = controller.deploy_targets(["11"])
        self.assertFalse(results[0][1])
        self.assertIn("staging failed", results[0][2])
        stop.assert_not_called()
        promote.assert_not_called()

    def test_import_stage_cache_runs_headless_import_and_validates_outputs(self):
        self.configure_studio()
        with mock.patch.object(
            controller,
            "ssh",
            side_effect=[completed(), completed()],
        ) as remote:
            ok, message = controller._import_stage_cache(
                "11",
                "/Users/francescospagnolo/Documents/watercouncil/.code.deploy-0123456789ab",
            )
        self.assertTrue(ok)
        self.assertIn("global classes ready", message)
        import_command = remote.call_args_list[0].args[1]
        self.assertIn("--headless", import_command)
        self.assertIn("--import", import_command)
        validation_command = remote.call_args_list[1].args[1]
        self.assertIn(controller.GLOBAL_CLASS_CACHE_RELATIVE_PATH, validation_command)
        self.assertIn(controller.FONT_CACHE_RELATIVE_PATH, validation_command)
        for class_name in controller.REQUIRED_GLOBAL_CLASSES:
            self.assertIn(f'"class": &"{class_name}"', validation_command)

    def test_verify_deployed_tree_requires_checksum_and_active_cache(self):
        self.configure_studio()
        source = Path("/source/project")
        project = controller.COMPUTERS["11"]["project"]
        with mock.patch.object(
            controller,
            "_verify_tree",
            return_value=(True, "checksum match"),
        ) as verify:
            with mock.patch.object(controller, "ssh", return_value=completed()) as remote:
                ok, message = controller._verify_deployed_tree(source, "11")
        self.assertTrue(ok)
        self.assertIn("global classes ready", message)
        verify.assert_called_once_with(source, controller.COMPUTERS["11"], project)
        validation_command = remote.call_args.args[1]
        self.assertIn(controller.GLOBAL_CLASS_CACHE_RELATIVE_PATH, validation_command)
        self.assertIn(controller.FONT_CACHE_RELATIVE_PATH, validation_command)
        for class_name in controller.REQUIRED_GLOBAL_CLASSES:
            self.assertIn(f'"class": &"{class_name}"', validation_command)

    def test_verify_deployed_tree_rejects_checksum_or_active_cache_failure(self):
        self.configure_studio()
        source = Path("/source/project")
        with mock.patch.object(
            controller,
            "_verify_tree",
            return_value=(False, "checksum mismatch"),
        ):
            with mock.patch.object(controller, "ssh") as remote:
                ok, message = controller._verify_deployed_tree(source, "11")
        self.assertFalse(ok)
        self.assertIn("checksum mismatch", message)
        remote.assert_not_called()

        with mock.patch.object(
            controller,
            "_verify_tree",
            return_value=(True, "checksum match"),
        ):
            with mock.patch.object(
                controller,
                "ssh",
                return_value=completed(returncode=15, stderr="font cache missing"),
            ):
                ok, message = controller._verify_deployed_tree(source, "11")
        self.assertFalse(ok)
        self.assertIn("active Godot cache validation failed", message)
        self.assertIn("font cache missing", message)

    def test_prepare_stage_requires_an_existing_installed_project(self):
        self.configure_studio()
        source = Path("/source/project")
        stage, backup = controller.deployment_paths(
            controller.COMPUTERS["11"],
            "0123456789ab",
        )
        with mock.patch.object(
            controller,
            "ssh",
            return_value=completed(returncode=14, stderr="Installed project missing"),
        ) as remote:
            with mock.patch.object(controller, "_rsync_project") as copy:
                ok, message = controller._prepare_stage("11", source, stage, backup)
        self.assertFalse(ok)
        self.assertIn("Installed project missing", message)
        self.assertIn(controller.COMPUTERS["11"]["project"], remote.call_args.args[1])
        copy.assert_not_called()

    def test_prepare_stage_imports_before_success(self):
        self.configure_studio()
        source = Path("/source/project")
        stage, backup = controller.deployment_paths(
            controller.COMPUTERS["11"],
            "0123456789ab",
        )
        with mock.patch.object(controller, "ssh", return_value=completed()):
            with mock.patch.object(controller, "_rsync_project", return_value=completed()):
                with mock.patch.object(
                    controller,
                    "_verify_tree",
                    side_effect=[(True, "match"), (True, "match")],
                ) as verify:
                    with mock.patch.object(
                        controller,
                        "_import_stage_cache",
                        return_value=(True, "cache ready"),
                    ) as imported:
                        ok, message = controller._prepare_stage("11", source, stage, backup)
        self.assertTrue(ok)
        self.assertIn("cache ready", message)
        imported.assert_called_once_with("11", stage)
        self.assertEqual(2, verify.call_count)

    def test_promotion_refuses_when_installed_project_disappears(self):
        self.configure_studio()
        stage, backup = controller.deployment_paths(
            controller.COMPUTERS["11"],
            "0123456789ab",
        )
        with mock.patch.object(
            controller,
            "ssh",
            return_value=completed(
                returncode=23,
                stderr="Installed project disappeared before promotion",
            ),
        ) as remote:
            ok, message = controller._promote_stage("11", stage, backup)
        self.assertFalse(ok)
        self.assertIn("disappeared", message)
        command = remote.call_args.args[1]
        self.assertIn(controller.COMPUTERS["11"]["project"], command)
        self.assertNotIn("NO_BACKUP", command)

    def test_successful_deploy_retains_backup_and_leaves_stopped(self):
        self.configure_studio()
        backup = "/Users/francescospagnolo/Documents/watercouncil/.code.backup-0123456789ab"
        with mock.patch.object(
            controller,
            "validate_deploy_source",
            return_value=Path("/source/project"),
        ):
            with mock.patch.object(os.path, "isfile", return_value=True):
                with mock.patch.object(controller.uuid, "uuid4") as generated:
                    generated.return_value.hex = "0123456789abcdef"
                    with mock.patch.object(controller, "_prepare_stage", return_value=(True, "ok")):
                        with mock.patch.object(
                            controller,
                            "stop_godot_processes",
                            return_value=completed(),
                        ):
                            with mock.patch.object(
                                controller,
                                "_promote_stage",
                                return_value=(True, backup),
                            ):
                                with mock.patch.object(
                                    controller,
                                    "_verify_deployed_tree",
                                    return_value=(True, "checksum and cache ready"),
                                ):
                                    with mock.patch.object(
                                        controller,
                                        "_cleanup_backup",
                                        return_value=(True, "old backup removed"),
                                    ) as cleanup:
                                        results = controller.deploy_targets(["11"])
        self.assertTrue(results[0][1])
        self.assertIn("left stopped", results[0][2])
        self.assertIn("old backup removed", results[0][2])
        cleanup.assert_called_once_with("11", backup)

    def test_post_promotion_mismatch_rolls_back(self):
        self.configure_studio()
        backup = "/Users/francescospagnolo/Documents/watercouncil/.code.backup-0123456789ab"
        with mock.patch.object(
            controller,
            "validate_deploy_source",
            return_value=Path("/source/project"),
        ):
            with mock.patch.object(os.path, "isfile", return_value=True):
                with mock.patch.object(controller.uuid, "uuid4") as generated:
                    generated.return_value.hex = "0123456789abcdef"
                    with mock.patch.object(controller, "_prepare_stage", return_value=(True, "ok")):
                        with mock.patch.object(
                            controller,
                            "stop_godot_processes",
                            return_value=completed(),
                        ):
                            with mock.patch.object(
                                controller,
                                "_promote_stage",
                                return_value=(True, backup),
                            ):
                                with mock.patch.object(
                                    controller,
                                    "_verify_deployed_tree",
                                    return_value=(False, "active cache mismatch"),
                                ):
                                    with mock.patch.object(
                                        controller,
                                        "_rollback_target",
                                        return_value=(True, "rolled back"),
                                    ) as rollback:
                                        with mock.patch.object(
                                            controller,
                                            "_cleanup_stage",
                                            return_value=(True, "clean"),
                                        ):
                                            results = controller.deploy_targets(["11"])
        self.assertFalse(results[0][1])
        self.assertIn("verification failed", results[0][2])
        rollback.assert_called_once()


if __name__ == "__main__":
    unittest.main()
