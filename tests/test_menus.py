"""Exercise real terminal menus with operations replaced by isolated stubs."""
import errno
import fcntl
import os
import pty
import select
import shlex
import signal
import subprocess
import termios
import time

from test_scripts import Harness, ROOT


class MenuHarness(Harness):
    def terminal(self, code, answers, expected_returncode=0):
        master, slave = pty.openpty()

        def attach_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(['bash', '-c', self.prefix + 'BBR_DD_AUTO_UPDATE=0\n' + code],
                                   stdin=slave, stdout=slave, stderr=slave,
                                   preexec_fn=attach_terminal)
        os.close(slave)
        output = bytearray()
        try:
            exchanges = []
            cursor = 0
            if isinstance(answers, str):
                os.write(master, answers.encode())
            else:
                exchanges = list(answers)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not data:
                        break
                    output.extend(data)
                    while exchanges:
                        prompt, response = exchanges[0]
                        match = output.find(prompt.encode(), cursor)
                        if match < 0:
                            break
                        cursor = match + len(prompt.encode())
                        exchanges.pop(0)
                        os.write(master, response.encode())
                elif process.poll() is not None:
                    break
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.fail('终端操作未按时结束：\n' + output.decode(errors='replace'))
            text = output.decode(errors='replace')
            expected = expected_returncode if isinstance(expected_returncode, tuple) else (expected_returncode,)
            self.assertIn(process.returncode, expected, text)
            self.assertFalse(exchanges, text)
            self.assertNotIn('执行以上操作', text)
            self.assertNotIn('仅预览，不修改系统', text)
            return text
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)


class TestBBRMenus(MenuHarness):
    script = 'bbr.sh'

    def test_exit_and_invalid_choice_do_not_dispatch(self):
        output = self.terminal('dispatch() { exit 93; }; main', 'x\n10\n11\n0\n')
        self.assertEqual(output.count('选项无效'), 3)
        self.assertNotIn('切换原版', output)
        self.assertNotIn('颜色：', output)
        self.assertNotIn('测试实验算法', output)
        self.assertNotIn('查看使用说明', output)
        self.assertNotIn('启用 Guard + fq', output)
        self.assertFalse(list(self.state.iterdir()))

    def test_status_returns_to_menu(self):
        output = self.terminal('dispatch() { echo "ROUTE=$ACTION"; }; main', '2\n0\n')
        self.assertIn('ROUTE=status', output)
        self.assertEqual(output.count('===== Guard '), 2)

    def test_nginx_installs_directly_after_method_selection(self):
        for option, method in [('1', ''), ('2', 'source')]:
            with self.subTest(option=option):
                output = self.terminal('''
require_host() { :; }
install_nginx() { echo "NGINX_METHOD=${1:-}:$DRY_RUN"; }
main
''', f'5\n{option}\n0\n')
                self.assertIn(f'NGINX_METHOD={method}:0', output)
                self.assertEqual(output.count('===== Guard '), 2)

    def test_install_and_build_only_guard(self):
        output = self.terminal('''
dispatch() { echo "ROUTE=$ACTION:$ALGORITHM:$BBR_MODULE:$CLOUD:$JOBS:$DRY_RUN"; }
main
''', '1\n1\n2\n1\n2\n1\n2\n0\n')
        self.assertIn('ROUTE=install:bbrguard:tcp_bbr_guard:gcp::0', output)
        self.assertIn('ROUTE=build:bbrguard:tcp_bbr_guard:auto:2:0', output)
        self.assertIn('1、安装 Guard7 R2（预编译 / 源码）', output)
        self.assertIn('源码编译安装（amd64 / arm64）', output)

    def test_submenu_zero_exits_entire_script(self):
        for answers in ['1\n0\n', '1\n1\n0\n', '1\n2\n0\n',
                        '1\n2\n1\n0\n', '5\n0\n']:
            with self.subTest(answers=answers):
                output = self.terminal('dispatch() { echo UNEXPECTED; }; main', answers)
                self.assertEqual(output.count('===== Guard '), 1)
                self.assertNotIn('UNEXPECTED', output)

    def test_all_actions_return_to_menu_on_success_and_failure(self):
        routes = [
            ('install', '1\n1\n1\n'), ('build', '1\n2\n1\n\n'),
            ('status', '2\n'), ('restore', '3\n'),
            ('cleanup', '4\n'), ('reboot', '9\n'),
            ('nginx', '5\n1\n'), ('nginx-source', '5\n2\n'),
            ('x-ui', '6\n'), ('openlist', '7\n'), ('app-info', '8\n'),
        ]
        for action, answers in routes:
            for ending in ['return 0', 'exit 0', 'false', "die '模拟任务失败'"]:
                with self.subTest(action=action, ending=ending):
                    output = self.terminal('''
dispatch() { echo "ROUTE=$ACTION"; ''' + ending + '''; echo UNSAFE; }
main
''', answers + '0\n')
                    self.assertIn('ROUTE=' + action, output)
                    self.assertNotIn('UNSAFE', output)
                    self.assertEqual(output.count('===== Guard '), 2)
                    self.assertNotIn('已返回主菜单', output)

    def test_panel_apps_install_directly(self):
        for option, app in [('6', 'x-ui'), ('7', 'openlist')]:
            output = self.terminal('''
require_host() { :; }
install_panel_app() { echo "INSTALL_APP=$1:$DRY_RUN"; }
main
''', option + '\n0\n')
            self.assertIn('INSTALL_APP=' + app + ':0', output)
            self.assertEqual(output.count('===== Guard '), 2)
            self.assertFalse(list(self.state.iterdir()))

    def test_cleanup_menu_explains_single_kernel_policy(self):
        output = self.terminal('''
require_host() { :; }
cleanup_old_kernels() { echo "CLEANUP=$DRY_RUN"; }
main
''', '4\n0\n')
        self.assertIn('4、清理其他内核（仅保留当前 BBR）', output)
        self.assertIn('CLEANUP=0', output)
        self.assertEqual(output.count('===== Guard '), 2)

    def test_failed_setup_returns_without_dispatching(self):
        output = self.terminal('''
menu_cloud() { false; touch "$STATE/unsafe-continuation"; }
dispatch() { echo "ROUTE=$ACTION"; }
main
''', '1\n1\n2\n0\n')
        self.assertNotIn('ROUTE=install', output)
        self.assertIn('ROUTE=status', output)
        self.assertFalse((self.state / 'unsafe-continuation').exists())
        self.assertEqual(output.count('===== Guard '), 3)

    def test_options_reset_after_each_action(self):
        output = self.terminal('''
dispatch() { echo "ROUTE=$ACTION:$CLOUD:$JOBS:$DRY_RUN"; DRY_RUN=1; }
main
''', '1\n2\n2\n4\n1\n1\n1\n2\n0\n')
        self.assertIn('ROUTE=build:gcp:4:0', output)
        self.assertIn('ROUTE=install:auto::0', output)
        self.assertIn('ROUTE=status:auto::0', output)

    def test_worker_force_exit_does_not_return_to_menu(self):
        for signal, status in [('INT', 130), ('TERM', 143), ('HUP', 129)]:
            with self.subTest(signal=signal):
                output = self.terminal('''
dispatch() {
    trap 'touch "$STATE/worker-cleaned"' EXIT
    kill -''' + signal + ''' "$BASHPID"
    touch "$STATE/unsafe-continuation"
}
main
''', '2\n0\n', expected_returncode=status)
                self.assertTrue((self.state / 'worker-cleaned').exists())
                self.assertFalse((self.state / 'unsafe-continuation').exists())
                self.assertEqual(output.count('===== Guard '), 1)
                self.assertNotIn('已返回主菜单', output)

    def test_terminal_ctrl_c_exits_main_submenu_and_running_task(self):
        prompt = '请输入选项数字（0 退出）：'
        for exchanges in [[(prompt, '\x03')],
                          [(prompt, '1\n'), (prompt, '\x03')],
                          [(prompt, '2\n'), ('ACTION_READY', '\x03')]]:
            with self.subTest(exchanges=exchanges):
                output = self.terminal('''
dispatch() {
    trap 'touch "$STATE/worker-cleaned"' EXIT
    python3 -u -c 'import time; print("ACTION_READY"); time.sleep(30)'
    touch "$STATE/unsafe-continuation"
}
main
''', exchanges, expected_returncode=(-2, 130))
                self.assertFalse((self.state / 'unsafe-continuation').exists())
                self.assertEqual(output.count('===== Guard '), 1)
                self.assertNotIn('已返回主菜单', output)
                if exchanges[-1][0] == 'ACTION_READY':
                    self.assertTrue((self.state / 'worker-cleaned').exists())

    def test_terminal_ctrl_d_exits_main_submenu_and_parameter_input(self):
        prompt = '请输入选项数字（0 退出）：'
        for exchanges in [[(prompt, '\x04')],
                          [(prompt, '1\n'), (prompt, '\x04')],
                          [(prompt, '1\n'), (prompt, '2\n'), (prompt, '1\n'),
                           ('编译并发数（留空自动，0 退出）：', '\x04')]]:
            with self.subTest(exchanges=exchanges):
                output = self.terminal('dispatch() { echo UNEXPECTED; }; main', exchanges)
                self.assertNotIn('UNEXPECTED', output)
                self.assertEqual(output.count('===== Guard '), 1)

    def test_failed_worker_stops_before_later_mutation_and_releases_control(self):
        output = self.terminal('''
dispatch() {
    if [[ $ACTION == restore ]]; then
        touch "$STATE/entered"
        false
        touch "$STATE/unsafe-continuation"
    else
        echo "ROUTE=$ACTION"
    fi
}
main
''', '3\n2\n0\n')
        self.assertTrue((self.state / 'entered').exists())
        self.assertFalse((self.state / 'unsafe-continuation').exists())
        self.assertIn('操作失败', output)
        self.assertIn('ROUTE=status', output)

    def test_reboot_executes_without_confirmation(self):
        output = self.terminal('''
require_host() { :; }
systemctl() { echo "$*" >> "$STATE/rebooted"; }
main
''', '9\n0\n')
        self.assertEqual((self.state / 'rebooted').read_text(), 'reboot\n')
        self.assertNotIn('1、确认重启', output)
        self.assertEqual(output.count('===== Guard '), 2)

    def test_legacy_cli_and_private_service_flag_rejected_on_public_script(self):
        for args in [('install',), ('enable', '--profile', 'upstream'), ('--internal-cleanup',)]:
            result = self.cli(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('中文数字菜单', result.stderr)

    def test_noninteractive_menu_is_refused(self):
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('交互终端', result.stderr)


class TestDDMenus(MenuHarness):
    script = 'dd.sh'

    def test_versions_prepare_with_fixed_password_login_and_automatic_options(self):
        for choice, version in [('1', '24.04'), ('2', '26.04')]:
            output = self.terminal('''
require_host() { :; }
reinstall_ubuntu() { echo "REINSTALL=$UBUNTU_VERSION:$CLOUD:$CACHE_MODE:$TEST_NETWORK:$DRY_RUN"; }
main
''', '1\n' + choice + '\n0\n')
            self.assertIn(f'REINSTALL={version}:auto:auto:0:0', output)
            self.assertIn('root 密码登录，SSH 端口 22', output)
            for removed in ['公钥文件路径', '选择 root 登录方式', 'SSH 端口（',
                            '选择云平台', '选择安装缓存', '选择安装流程']:
                self.assertNotIn(removed, output)
            self.assertFalse(list(self.state.iterdir()))

    def test_options_reset_after_each_operation(self):
        output = self.terminal('''
dispatch() { echo "ROUTE=$UBUNTU_VERSION:$CLOUD:$CACHE_MODE:$TEST_NETWORK:$DRY_RUN"; DRY_RUN=1; CLOUD=oci; CACHE_MODE=disk; TEST_NETWORK=1; }
main
''', '1\n2\n1\n1\n0\n')
        self.assertIn('ROUTE=26.04:auto:auto:0:0', output)
        self.assertIn('ROUTE=24.04:auto:auto:0:0', output)

    def test_every_reinstall_submenu_accepts_zero(self):
        for answers in ['1\n0\n', '1\n9\n0\n']:
            output = self.terminal('dispatch() { exit 93; }; main', answers)
            self.assertEqual(output.count('===== Ubuntu DD'), 1)

    def test_target_display_continues_without_confirmation(self):
        output = self.terminal('''
SYSTEM_DISK=/dev/mock
lsblk() { echo 'mock 16G disk'; }
dispatch() { show_reinstall_target; touch "$STATE/preparing"; }
run_menu_action
''', '')
        self.assertTrue((self.state / 'preparing').exists())
        self.assertIn('系统盘 /dev/mock', output)
        self.assertIn('mock 16G disk', output)
        self.assertIn('重启后会清除此磁盘的所有分区和数据', output)
        self.assertIn('不自动重启', output)
        self.assertNotIn('请输入选项数字', output)

    def test_password_flow_does_not_pass_ssh_key(self):
        engine = self.state / 'engine.sh'
        engine.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$STATE/args"\n'
                          'printf "%s" "fixture-secret" >&8\n')
        output = self.terminal('''
require_host() { :; }
secure_boot_check() { :; }
inspect_cloud() { :; }
detect_system_disk() { SYSTEM_DISK=/dev/mock; }
lsblk() { echo 'mock 16G disk'; }
prepare_image_policy() { DD_IMAGE_URL=https://example.invalid/verified.img; }
systemctl() { echo UNEXPECTED_REBOOT; }
''' + f'prepare_engine() {{ ENGINE={shlex.quote(str(engine))}; }}\nmain',
                      '1\n1\n0\n')
        self.assertNotIn('UNEXPECTED_REBOOT', output)
        self.assertNotIn('确认清空', output)
        self.assertIn('Ubuntu 重装已准备，尚未重启', output)
        self.assertEqual(output.count('===== Ubuntu DD'), 2)
        args = (self.state / 'args').read_text().splitlines()
        self.assertNotIn('--ssh-key', args)
        self.assertNotIn('--hold', args)
        self.assertEqual(args[args.index('--username') + 1], 'root')
        self.assertEqual(args[args.index('--ssh-port') + 1], '22')
        self.assertNotIn('--password', args)
        self.assertEqual((self.state / 'login-password').read_text(), 'fixture-secret')
        self.assertEqual((self.state / 'login-password').stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.state / 'reinstall-ready').is_file())

    def test_reboot_requires_one_confirmation(self):
        for answers, count, rebooted in [('0\n', 1, False), ('2\n0\n', 2, False),
                                         ('1\n0\n', 2, True)]:
            with self.subTest(answers=answers):
                marker = self.state / 'rebooted'
                marker.unlink(missing_ok=True)
                output = self.terminal('''
require_host() { :; }
systemctl() { echo "$*" >> "$STATE/rebooted"; }
main
''', '4\n' + answers)
                self.assertEqual(marker.exists(), rebooted)
                if rebooted:
                    self.assertEqual(marker.read_text(), 'reboot\n')
                self.assertEqual(output.count('1、确认重启当前系统'), 1)
                self.assertEqual(output.count('===== Ubuntu DD'), count)
                self.assertNotIn('用户名：', output)
                self.assertNotIn('密码：', output)

    def test_all_operations_return_to_menu_on_success_and_failure(self):
        routes = [('reinstall', '1\n1\n'), ('reinstall', '1\n2\n'),
                  ('status', '2\n'), ('cancel', '3\n'), ('reboot', '4\n1\n')]
        for action, answers in routes:
            for ending in ['return 0', 'exit 0', 'false', "die '模拟任务失败'"]:
                with self.subTest(action=action, ending=ending):
                    # Keep real dispatch and reboot confirmation; mock only host operations.
                    output = self.terminal('''
require_host() { :; }
operation() { echo "ROUTE=$ACTION:$DRY_RUN"; ''' + ending + '''; echo UNSAFE; }
reinstall_ubuntu() { operation; }
cloud_status() { operation; }
cancel_reinstall() { operation; }
systemctl() { operation; }
main
''', answers + '0\n')
                    self.assertIn('ROUTE=' + action + ':0', output)
                    self.assertNotIn('UNSAFE', output)
                    self.assertEqual(output.count('===== Ubuntu DD'), 2)
                    self.assertNotIn('已返回主菜单', output)

    def test_compact_main_menu_rejects_removed_options(self):
        output = self.terminal('dispatch() { exit 93; }; main', '5\n6\n0\n')
        self.assertNotIn('颜色：', output)
        self.assertNotIn('查看使用说明', output)
        self.assertNotIn('（准备 DD 后开始安装）', output)
        self.assertIn('1、重装系统', output)
        self.assertIn('4、重启系统', output)
        self.assertEqual(output.count('选项无效'), 2)

    def test_prepared_login_is_colored_before_reboot_confirmation_after_restart(self):
        password = 'literal-$(touch ' + str(self.state / 'injected') + ')-%s'
        (self.state / 'reinstall-pending').touch()
        (self.state / 'reinstall-ready').touch()
        record = self.state / 'login-password'
        record.write_text(password)
        record.chmod(0o600)
        for plain in [False, True]:
            settings = 'export TERM=xterm; ' + ('export NO_COLOR=1' if plain else 'unset NO_COLOR')
            output = self.terminal(settings + '''
require_host() { :; }
systemctl() { echo "$*" >> "$STATE/rebooted"; }
main
''', '4\n2\n0\n')
            self.assertIn('用户名：root', output)
            self.assertIn('密码：' + password, output)
            self.assertLess(output.index('密码：'), output.index('1、确认重启'))
            if plain:
                self.assertNotIn('\x1b[', output)
            else:
                self.assertIn('\x1b[1;36m用户名：root\x1b[0m', output)
                self.assertIn('\x1b[1;33m密码：' + password + '\x1b[0m', output)
            self.assertFalse((self.state / 'rebooted').exists())
            self.assertFalse((self.state / 'injected').exists())

    def test_incomplete_preparation_or_unsafe_login_record_blocks_reboot(self):
        (self.state / 'reinstall-pending').touch()
        record = self.state / 'login-password'
        target = self.root / 'secret-target'
        target.write_text('do-not-display')
        for invalid in ['not-ready', 'missing', 'symlink', 'mode', 'empty', 'control']:
            with self.subTest(invalid=invalid):
                record.unlink(missing_ok=True)
                (self.state / 'reinstall-ready').unlink(missing_ok=True)
                if invalid != 'not-ready':
                    (self.state / 'reinstall-ready').touch()
                if invalid == 'symlink':
                    record.symlink_to(target)
                elif invalid not in ['not-ready', 'missing']:
                    record.write_text('' if invalid == 'empty' else 'bad\nline' if invalid == 'control' else 'do-not-display')
                    record.chmod(0o644 if invalid == 'mode' else 0o600)
                output = self.terminal('''
require_host() { :; }
systemctl() { touch "$STATE/rebooted"; }
main
''', '4\n0\n')
                self.assertNotIn('用户名：', output)
                self.assertNotIn('do-not-display', output)
                self.assertFalse((self.state / 'rebooted').exists())

    def test_shared_menu_helpers_embedded_verbatim(self):
        helper = (ROOT / 'tools/menu_helpers.inc').read_text().strip()
        for name in ('bbr.sh', 'dd.sh'):
            self.assertIn(helper, (ROOT / name).read_text())
