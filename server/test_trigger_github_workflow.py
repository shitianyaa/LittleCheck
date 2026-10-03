import io
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch

import trigger_github_workflow as trigger


class TriggerTests(unittest.TestCase):
    def invoke(self, results):
        output = io.StringIO()
        with patch.object(trigger.subprocess, 'run', side_effect=results) as run, \
             redirect_stdout(output), redirect_stderr(output):
            status = trigger.main()
        return status, run, output.getvalue()

    def test_dispatch_uses_dedicated_account_and_ignores_inherited_tokens(self):
        with patch.dict(trigger.os.environ, {'GH_TOKEN': 'test-placeholder', 'GITHUB_TOKEN': 'test-placeholder'}):
            status, run, output = self.invoke([Mock(returncode=0, stdout='yuri1s\n'), Mock(returncode=0)])
        self.assertEqual(status, 0)
        args, kwargs = run.call_args
        self.assertEqual(args[0], ['gh', 'workflow', 'run', 'publish.yml', '--repo',
                                  'github.com/yuri1s/LittleCheck-Feed', '--ref', 'main'])
        self.assertEqual(kwargs['env']['GH_CONFIG_DIR'], str(Path(trigger.__file__).resolve().parent/'github-auth'))
        self.assertNotIn('GH_TOKEN', kwargs['env'])
        self.assertNotIn('GITHUB_TOKEN', kwargs['env'])
        self.assertIn('dispatch accepted', output)

    def test_wrong_or_missing_login_never_dispatches(self):
        for account in [Mock(returncode=0, stdout='shitianyaa'), Mock(returncode=1, stdout='')]:
            with self.subTest(account=account):
                status, run, output = self.invoke([account])
                self.assertEqual(status, 1)
                self.assertEqual(run.call_count, 1)
                self.assertIn('dedicated login must be yuri1s', output)

    def test_dispatch_failure_does_not_log_cli_output_or_claim_success(self):
        status, run, output = self.invoke([Mock(returncode=0, stdout='yuri1s'),
                                         Mock(returncode=1, stderr='private CLI detail')])
        self.assertEqual(status, 1)
        self.assertEqual(run.call_count, 2)
        self.assertNotIn('private CLI detail', output)
        self.assertNotIn('dispatch accepted', output)

    def test_timeout_or_missing_cli_is_reported_without_retry(self):
        for error in [subprocess.TimeoutExpired('gh', 30), FileNotFoundError('gh')]:
            with self.subTest(error=error):
                status, run, output = self.invoke([Mock(returncode=0, stdout='yuri1s'), error])
                self.assertEqual(status, 1)
                self.assertEqual(run.call_count, 2)
                self.assertIn(type(error).__name__, output)
                self.assertIn('feed remains published', output)


if __name__ == '__main__':
    unittest.main()
