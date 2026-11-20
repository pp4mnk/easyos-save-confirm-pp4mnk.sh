#!/bin/sh
# Save confirmation for EasyOS Excalibur — pp4mnk
set -eu
exec python3 - "$0" "$@" <<'PY'
import errno
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

NATIVE = Path('/usr/sbin/ask-save-zram1')
HELPER = Path('/usr/local/libexec/easyos-save-confirm-pp4mnk.sh')
BACKUP = HELPER.with_suffix('.original')
UPPER = Path('/mnt/.easy_rw')
WORK = Path('/mnt/wkg')
STAGED = WORK / '.shutdown/easy_rw'
OLD = b' RETSTRING0="$(gtkdialog --program=SS_DLG0 --center)"\n'
NEW = b' RETSTRING0="$(pp4mnk_save_dialog)"\n'
SECTION = b'###top-level-zram###\n'
MARKER = b'# BEGIN pp4mnk save confirmation\n'
HOOK = br'''# BEGIN pp4mnk save confirmation
pp4mnk_save_dialog() {
 while :; do
  pp4mnk_result="$(gtkdialog --program=SS_DLG0 --center)" || return 1
  case "$pp4mnk_result" in
   *'EXIT="yes"'*) pp4mnk_choice=yes ;;
   *'EXIT="no"'*) pp4mnk_choice=no ;;
   *'EXIT="abort"'*) pp4mnk_choice=abort ;;
   *) continue ;;
  esac
  if /bin/sh /usr/local/libexec/easyos-save-confirm-pp4mnk.sh \
       --confirm "$pp4mnk_choice" "$STATUS" "$EOS_SUPPORT_CONTAINERS"; then
   if [ "$STATUS" = shutdown ] && [ "$pp4mnk_choice" = abort ]; then
    printf '%s\n' 'EXIT="no"'
   else
    printf '%s\n' "$pp4mnk_result"
   fi
   return 0
  fi
 done
}
# END pp4mnk save confirmation
'''


def native_patch(original):
    before, marker, after = original.partition(SECTION)
    if (not marker or before.count(OLD) != 1 or after.count(OLD) != 2
            or b'.shutdown/easy_rw' not in after
            or br'type=\"exit\">no</action>' not in after
            or br'type=\"exit\">yes</action>' not in after):
        raise ValueError('The native dialog differs from the one in EasyOS Excalibur 7.5.3.')
    head, newline, body = before.partition(b'\n')
    return head + newline + HOOK + body + marker + after.replace(OLD, NEW)


def atomic_write(path, contents, mode):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.pp4mnk-', delete=False) as output:
        temp = Path(output.name)
        try:
            output.write(contents)
            output.flush()
            os.fchmod(output.fileno(), mode)
            os.fsync(output.fileno())
            temp.replace(path)
        finally:
            temp.unlink(missing_ok=True)


def install(uninstall):
    if os.geteuid() != 0 or NATIVE.is_symlink() or not NATIVE.is_file():
        raise ValueError('Run the installer as root from the main EasyOS desktop.')
    original = NATIVE.read_bytes()
    mode = stat.S_IMODE(NATIVE.stat().st_mode)
    if uninstall:
        if MARKER in original:
            if not BACKUP.is_file() or native_patch(BACKUP.read_bytes()) != original:
                raise ValueError(f'The current dialog differs from the installed version. Original backup: {BACKUP}')
            atomic_write(NATIVE, BACKUP.read_bytes(), mode)
        elif BACKUP.exists() and BACKUP.read_bytes() != original:
            raise ValueError(f'The current dialog differs from the backup at {BACKUP}.')
        if BACKUP.is_file():
            HELPER.unlink(missing_ok=True)
            BACKUP.unlink()
        print('Restored the original EasyOS dialog.')
        return

    if not shutil.which('yad') or not Path('/etc/rc.d/PUPSTATE').is_file():
        raise ValueError('EasyOS Excalibur with YAD is required.')
    merge = Path('/etc/rc.d/rw-merge').read_bytes()
    if b'--exclude=./var/tmp0' not in merge or b'endDEST}/session1' not in merge:
        raise ValueError('The save rules differ from those in EasyOS Excalibur 7.5.3.')
    if MARKER in original:
        if BACKUP.is_file() and native_patch(BACKUP.read_bytes()) == original and HELPER.is_file():
            atomic_write(HELPER, Path(sys.argv[1]).read_bytes(), 0o755)
            print('Save confirmation updated. Save the session to keep the update.')
            return
        raise ValueError(f'The installation has been modified. Original backup: {BACKUP}')
    patched = native_patch(original)
    if BACKUP.exists() and BACKUP.read_bytes() != original:
        raise ValueError(f'A different backup already exists at {BACKUP}.')
    if HELPER.exists() and not BACKUP.is_file():
        raise ValueError(f'Another file already exists at {HELPER}.')
    HELPER.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(BACKUP, original, 0o644)
    atomic_write(HELPER, Path(sys.argv[1]).read_bytes(), 0o755)
    atomic_write(NATIVE, patched, mode)
    print('Installed. Open the Save icon and save the session to keep the installation.')


def lstat(path):
    try:
        return path.lstat()
    except (FileNotFoundError, NotADirectoryError):
        return None


def overlay_attribute(path, attribute):
    for namespace in ('trusted', 'user'):
        try:
            return os.getxattr(path, f'{namespace}.overlay.{attribute}', follow_symlinks=False)
        except OSError as error:
            if error.errno not in (errno.ENODATA, errno.ENOTSUP, errno.EPERM,
                                   errno.EACCES, errno.ENOENT):
                raise


def whiteout(path, info):
    return ((stat.S_ISCHR(info.st_mode) and info.st_rdev == 0)
            or (stat.S_ISREG(info.st_mode) and info.st_size == 0
                and overlay_attribute(path, 'whiteout') is not None))


def opaque(path):
    return (overlay_attribute(path, 'opaque') == b'y'
            or (path / '.wh..wh..opq').is_file())


VISIBLE_TREES = ('root', 'home', 'etc', 'usr/local/bin', 'usr/local/sbin',
                 'usr/local/share/applications')
AUTOMATIC_PATHS = {
    '.local/share/Trash', '.local/share/gvfs-metadata', '.local/share/recently-used.xbel',
    '.config/dconf/user.lock', '.config/pulse', '.config/session', '.config/sessions',
    '.config/rox.sourceforge.net/ROX-Filer/RecentlyUsed', 'Choices/ROX-Filer/RecentlyUsed',
    '.dbus/session-bus', '.thumbnails', '.pki/nssdb', 'etc/.pwd.lock',
    'etc/adjtime', 'etc/mtab', 'etc/resolv.conf', 'etc/machine-id', 'etc/udev/hwdb.bin',
    'etc/rc.d/PUPSTATE',
}
BROWSER_PROFILES = {'.mozilla/firefox', '.config/chromium', '.config/google-chrome',
                    '.config/opera', '.config/opera-stable', '.config/slimjet',
                    '.config/BraveSoftware', '.config/microsoft-edge'}
BROWSER_PERSONAL = {'Bookmarks', 'user.js', 'userChrome.css', 'userContent.css'}


def under(path, prefix):
    return path == prefix or path.startswith(prefix + '/')


def excluded(relative, shared, directory):
    parts = relative.parts
    name = relative.as_posix()
    if not any(under(name, prefix) or (directory and under(prefix, name))
               for prefix in VISIBLE_TREES):
        return True
    if any(under(name, prefix) for prefix in shared) or '.cache' in parts:
        return True

    home_path = ''
    if parts[0] in {'root', 'home'}:
        home_path = '/'.join(parts[1:] if parts[0] == 'root' else parts[2:])
    if any(under(name, prefix) or under(home_path, prefix) for prefix in AUTOMATIC_PATHS):
        return True
    if (relative.name in {'.Xauthority', '.ICEauthority', '.XLOADED', '.xsession-errors',
                          '.xsession-errors.old', '.lesshst', '.viminfo', '.wget-hsts'}
            or relative.name.startswith('.xsession-errors-')
            or relative.name.endswith(('.log', '.lock', '.pid', '.tmp', '.swp', '.swo',
                                       '_history', '.crdownload', '.part'))):
        return True
    if any(under(home_path, prefix) for prefix in BROWSER_PROFILES):
        if any(part in {'Cache', 'Code Cache', 'GPUCache', 'cache2', 'shader-cache',
                        'Service Worker', 'Crash Reports', 'Crashpad'} for part in parts):
            return True
        return not directory and relative.name not in BROWSER_PERSONAL
    return False


def inventory(layer, shared):
    root_dev = layer.stat().st_dev

    def scan(directory, parent):
        try:
            children = os.scandir(directory)
        except FileNotFoundError:
            return
        with children as entries:
            for entry in entries:
                path = Path(entry.path)
                relative = parent / entry.name
                is_directory = entry.is_dir(follow_symlinks=False)
                if entry.name.startswith('.wh.') or excluded(relative, shared, is_directory):
                    continue
                info = lstat(path)
                if info is None or info.st_dev != root_dev:
                    continue
                if stat.S_ISDIR(info.st_mode):
                    yield from scan(path, relative)
                elif stat.S_ISLNK(info.st_mode) or (
                        stat.S_ISREG(info.st_mode) and not whiteout(path, info)):
                    yield relative, path, info

    yield from scan(layer, Path())


def working_lowers(name):
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        left, _, right = line.partition(' - ')
        fields = right.split()
        if len(fields) < 3 or fields[0] != 'overlay':
            continue
        options = dict(option.split('=', 1) for option in fields[2].split(',') if '=' in option)
        upper = options.get('upperdir', '').rstrip('/')
        match = (left.split()[4] == '/' if name == 'mainrw'
                 else upper.endswith('/' + name) and 'easy_rw' in upper)
        if not match or 'lowerdir' not in options:
            continue
        layers = []
        for raw in options['lowerdir'].split(':'):
            decoded = re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), raw)
            layer = Path(decoded)
            if not layer.is_dir() and decoded.startswith('/easy_ro/'):
                layer = Path('/mnt/.easy_ro') / decoded.removeprefix('/easy_ro/')
            layers.append(layer)
        if layers and all(layer.is_dir() for layer in layers):
            return layers
    if name == 'mainrw':
        base = Path('/mnt/.easy_ro/easy_sfs')
        if base.is_dir():
            return [layer for layer in (WORK / '.session/session1', base) if layer.is_dir()]
    return []


def lower_entry(layers, relative):
    for layer in layers:
        directory = layer
        for part in relative.parts:
            if (directory / ('.wh.' + part)).is_file():
                return None
            item = directory / part
            info = lstat(item)
            if info is None:
                if opaque(directory):
                    return None
                break
            if whiteout(item, info):
                return None
            if item == layer / relative:
                return item, info
            if not stat.S_ISDIR(info.st_mode):
                return None
            directory = item
    return None


def same_file(path, info, prior_path, prior):
    # OverlayFS copy-ups and timestamp-only updates do not change file contents.
    if info.st_mode != prior.st_mode:
        return False
    if stat.S_ISLNK(info.st_mode):
        return os.readlink(path) == os.readlink(prior_path)
    if info.st_size != prior.st_size:
        return False
    with path.open('rb') as current, prior_path.open('rb') as previous:
        for block in iter(lambda: current.read(1024 * 1024), b''):
            if block != previous.read(len(block)):
                return False
        return not previous.read(1)


def show_path(name, relative):
    path = '/' + relative.as_posix() if relative.parts else '/'
    path = ''.join(char if char.isprintable() else repr(char)[1:-1] for char in path)
    return path if name == 'mainrw' else f'[{name}] {path}'

def render(mode, action, support):
    if not (UPPER / 'mainrw').is_dir():
        raise ValueError('No RAM session layer was found at /mnt/.easy_rw/mainrw.')
    labels = ('New files', 'Modified files')
    sections = {label: [] for label in labels}
    unavailable = set()
    staged = STAGED.is_dir()
    names = {'mainrw'}
    if support != '0':
        names.update(entry.name for entry in UPPER.iterdir()
                     if entry.is_dir() and 'tempwork' not in entry.name)
    for name in sorted(names, key=lambda candidate: (candidate != 'mainrw', candidate)):
        shared = set()
        if name == 'mainrw':
            shared.add('files')
        else:
            config = WORK / 'containers' / name / 'configuration'
            if config.is_file():
                match = re.search(r"^EC_ACCESS_FOLDER_PATH='(/[^']+)'", config.read_text(), re.M)
                if match:
                    shared.add(match[1].strip('/'))
        layer = UPPER / name
        saved = STAGED / name
        lower = working_lowers(name)
        comparison_layers = [saved, *lower] if saved.is_dir() else lower
        for relative, path, info in inventory(layer, shared):
            try:
                prior = lower_entry(comparison_layers, relative)
                if prior is None and not lower:
                    unavailable.add(name)
                    continue
                if prior is not None and same_file(path, info, *prior):
                    continue
            except FileNotFoundError:
                # An application may replace a file while the preview is built.
                unavailable.add(name)
                continue
            section = 'Modified files' if prior is not None else 'New files'
            sections[section].append(show_path(name, relative))

    if action == 'yes':
        consequence = ('EasyOS will save the session changes when you shut down or restart.'
                       if mode == 'shutdown' else
                       'EasyOS will prepare a copy and apply it when you shut down or restart.')
    elif mode == 'shutdown':
        consequence = ('Pending changes will be lost. EasyOS will apply the prepared copy.'
                       if staged else 'Session changes still in RAM will be lost.')
        auto = Path('/var/local/zram1-save-shutdown-auto')
        if auto.is_file() and auto.read_text().strip() == 'true':
            consequence = 'Automatic saving is enabled. EasyOS will save the session at shutdown.'
    else:
        consequence = 'Changes will stay in RAM. You can save them later.'
        if staged:
            consequence += ' The prepared copy will be kept.'

    lines = [consequence]
    if unavailable:
        names = ', '.join('the main session' if name == 'mainrw' else name
                          for name in sorted(unavailable))
        lines.extend(['', f'Could only compare some files in {names}.'])
    if not any(sections.values()) and not unavailable:
        lines.extend(['', 'No new or modified personal files are pending.'])
    for label, entries in sections.items():
        if entries:
            lines.extend(['', f'{label} ({len(entries)})', *sorted(entries, key=str.casefold)])
    return '\n'.join(lines) + '\n'


def dialog(report, title, confirm=None):
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', errors='backslashreplace') as output:
        output.write(report)
        output.flush()
        args = ['yad', '--text-info', '--filename=' + output.name, '--width=860', '--height=565',
                '--center', '--title=' + title, '--fontname=Monospace 10']
        if confirm:
            args += ['--button=Back:1', '--button=' + confirm + ':0']
        else:
            args += ['--button=Close:1']
        return subprocess.run(args, stdout=subprocess.DEVNULL, check=False).returncode


def main():
    args = sys.argv[2:]
    command = args[0] if args else '--install'
    if command in ('--install', '--uninstall') and len(args) <= 1:
        install(command == '--uninstall')
        return 0
    if command == '--preview' and len(args) == 1:
        state = Path('/etc/rc.d/PUPSTATE').read_text(errors='replace')
        match = re.search(r"^EOS_SUPPORT_CONTAINERS=['\"]?(\d+)", state, re.M)
        dialog(render('running', 'yes', match[1] if match else ''), 'EasyOS · Changes in RAM')
        return 0
    if command == '--confirm' and len(args) == 4:
        _, action, mode, support = args
        confirm = {'yes': 'Confirm save', 'no': 'Continue without saving',
                   'abort': 'Confirm cancellation'}[action]
        if mode == 'shutdown' and action == 'abort':
            confirm = 'Continue without saving'
        try:
            report = render(mode, action, support)
        except (OSError, ValueError) as error:
            dialog(f'Could not inspect the session in RAM.\n\n{error}\n',
                   'EasyOS · Preview unavailable')
            return 1
        return dialog(report, 'EasyOS · ' + confirm, confirm)
    usage = f'Usage: sh {Path(sys.argv[1]).name} [--install|--preview|--uninstall]'
    if command == '--help':
        print(usage)
        return 0
    raise ValueError(usage)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f'EasyOS Save · {error}', file=sys.stderr)
        sys.exit(1)
PY
