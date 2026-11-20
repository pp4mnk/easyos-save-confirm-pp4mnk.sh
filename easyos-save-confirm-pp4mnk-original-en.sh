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


def whiteout(info):
    return stat.S_ISCHR(info.st_mode) and info.st_rdev == 0


def opaque(path):
    for name in ('trusted.overlay.opaque', 'user.overlay.opaque'):
        try:
            if os.getxattr(path, name, follow_symlinks=False) == b'y':
                return True
        except OSError as error:
            if error.errno not in (errno.ENODATA, errno.ENOTSUP, errno.EPERM, errno.EACCES):
                raise
    return False


def excluded(relative, shared):
    top = relative.parts[0]
    name = relative.as_posix()
    flag = len(relative.parts) == 2 and top == '.control' and relative.name.endswith('-flag')
    return (top.startswith('.') and not flag
            or top in {'dev', 'mnt', 'run', 'proc', 'sys', 'tmp', 'lost+found'}
            or '.cache' in relative.parts
            or any(name == item or name.startswith(item + '/') for item in shared))


def inventory(layer, shared):
    records = {}
    root_dev = layer.stat().st_dev

    def scan(directory, parent):
        try:
            children = os.scandir(directory)
        except (FileNotFoundError, NotADirectoryError):
            return
        with children as entries:
            for entry in entries:
                path = Path(entry.path)
                relative = parent / entry.name
                info = lstat(path)
                if info is None or info.st_dev != root_dev or stat.S_ISSOCK(info.st_mode):
                    continue
                # rw-merge processes whiteouts separately, before applying tar exclusions.
                if whiteout(info):
                    records[relative] = ('deleted', path, info)
                elif stat.S_ISREG(info.st_mode) and entry.name.startswith('.wh.'):
                    if entry.name == '.wh..wh..opq':
                        records[parent] = ('opaque', path, info)
                    elif len(entry.name) > 4:
                        records[parent / entry.name[4:]] = ('deleted', path, info)
                elif stat.S_ISDIR(info.st_mode):
                    if opaque(path):
                        records[relative] = ('opaque', path, info)
                    scan(path, relative)
                    if not excluded(relative, shared):
                        records.setdefault(relative, ('dir', path, info))
                elif not excluded(relative, shared):
                    records[relative] = ('file', path, info)

    scan(layer, Path())
    return records


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


def lower_info(layers, relative):
    for layer in layers:
        directory = layer
        for part in relative.parts:
            if (directory / ('.wh.' + part)).is_file():
                return None
            item = directory / part
            info = lstat(item)
            if info is None:
                if opaque(directory) or (directory / '.wh..wh..opq').is_file():
                    return None
                break
            if whiteout(info):
                return None
            if item == layer / relative:
                return info
            if not stat.S_ISDIR(info.st_mode):
                return None
            directory = item
    return None


def copied_version(live, copied):
    kind, path, info = live
    prior_kind, prior_path, prior = copied
    if kind != prior_kind:
        return False
    if kind in ('deleted', 'opaque'):
        return True
    if (info.st_mode, info.st_uid, info.st_gid, info.st_mtime_ns) != (
            prior.st_mode, prior.st_uid, prior.st_gid, prior.st_mtime_ns):
        return False
    if stat.S_ISLNK(info.st_mode):
        return os.readlink(path) == os.readlink(prior_path)
    if stat.S_ISREG(info.st_mode):
        if info.st_size != prior.st_size:
            return False
        if info.st_size <= 1024 * 1024:
            return path.read_bytes() == prior_path.read_bytes()
        return None
    return info.st_rdev == prior.st_rdev


def show_path(name, relative):
    path = '/' + relative.as_posix() if relative.parts else '/'
    path = ''.join(char if char.isprintable() else repr(char)[1:-1] for char in path)
    return path if name == 'mainrw' else f'[{name}] {path}'

def describe_prior(path, kind):
    detail = {'deleted': ' · deletion', 'opaque': ' · directory replaced', 'dir': ' · directory'}
    return path + detail.get(kind, '')


def render(mode, action, support):
    if not (UPPER / 'mainrw').is_dir():
        raise ValueError('No RAM session layer was found at /mnt/.easy_rw/mainrw.')
    labels = ('New', 'Modified or copied into RAM', 'Deleted',
              'Replaced directories', 'Unclassified changes',
              'Already in the prepared copy', 'Only in the prepared copy')
    sections = {label: [] for label in labels}
    staged = STAGED.is_dir()
    names = {'mainrw'}
    if support != '0':
        for root in (UPPER, STAGED):
            if root.is_dir():
                names.update(entry.name for entry in root.iterdir()
                             if entry.is_dir() and 'tempwork' not in entry.name)
    for name in sorted(names, key=lambda candidate: (candidate != 'mainrw', candidate)):
        shared = {'root/.XLOADED', 'var/cache', 'var/run', 'var/tmp0', 'var/lock', 'var/lib/flatpak'}
        if Path('/var').is_symlink():
            shared.add('var')
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
        live = inventory(layer, shared) if layer.is_dir() else {}
        previous = inventory(saved, shared) if saved.is_dir() else {}
        lower = working_lowers(name) if live else []
        for relative, record in live.items():
            kind = record[0]
            path = show_path(name, relative)
            baseline = lower_info(lower, relative) if lower and relative.parts else None
            if kind == 'dir' and baseline is not None and stat.S_ISDIR(baseline.st_mode):
                # OverlayFS also copies parent directories while writing descendants.
                continue
            version = copied_version(record, previous[relative]) if relative in previous else False
            if version:
                sections['Already in the prepared copy'].append(describe_prior(path, kind))
                continue
            if kind == 'deleted':
                section = 'Deleted'
            elif kind == 'opaque':
                section = 'Replaced directories'
            elif baseline is not None:
                section = 'Modified or copied into RAM'
            else:
                section = 'New' if lower else 'Unclassified changes'
            suffix = ' (directory)' if kind == 'dir' else ''
            if version is None:
                suffix += ' · metadata matches the prepared copy'
            elif relative in previous:
                suffix += ' · an earlier version is in the prepared copy'
            sections[section].append(path + suffix)
        for relative, record in previous.items():
            if relative not in live and record[0] != 'dir':
                sections['Only in the prepared copy'].append(describe_prior(show_path(name, relative), record[0]))

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

    lines = [consequence, '',
             'Changes under /files are saved directly to disk. Session saving excludes caches and temporary files.',
             'This list shows what was in the session layer when this window opened.']
    if not any(sections.values()):
        lines.extend(['', 'No session changes were found in RAM.'])
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
