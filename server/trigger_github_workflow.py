"""Request a Pages workflow run using the VPS's dedicated GitHub CLI login."""
import os
from pathlib import Path
import subprocess
import sys


def main():
    env = os.environ.copy()
    # An inherited token must not override the dedicated account's stored login.
    for key in ('GH_TOKEN', 'GITHUB_TOKEN'):
        env.pop(key, None)
    env.update(GH_CONFIG_DIR=str(Path(__file__).resolve().parent / 'github-auth'),
               GH_HOST='github.com', GH_PROMPT_DISABLED='1')
    try:
        account = subprocess.run(
            ['gh', 'api', '--hostname', 'github.com', 'user', '--jq', '.login'],
            env=env, capture_output=True, text=True, timeout=30, check=False)
        if account.returncode or account.stdout.strip() != 'yuri1s':
            print('GitHub trigger failed: dedicated login must be yuri1s; reauthorize github-auth.', file=sys.stderr)
            return 1
        result = subprocess.run(
            ['gh', 'workflow', 'run', 'publish.yml', '--repo', 'github.com/yuri1s/LittleCheck-Feed', '--ref', 'main'],
            env=env, capture_output=True, text=True, timeout=30, check=False)
        if result.returncode:
            print(f'GitHub trigger failed: workflow dispatch returned exit {result.returncode}; check account permissions and connectivity.', file=sys.stderr)
            return 1
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f'GitHub trigger failed: {type(error).__name__}; feed remains published.', file=sys.stderr)
        return 1
    print('GitHub workflow dispatch accepted; check Actions for deployment completion.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
