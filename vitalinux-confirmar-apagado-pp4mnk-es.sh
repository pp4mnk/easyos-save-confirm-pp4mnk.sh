#!/bin/sh
# Revisión de cambios antes de apagar Vitalinux — pp4mnk
exec /usr/bin/python3 - "$0" "$@" <<'PY'
import argparse
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import NamedTuple

HOME = Path.home()
FILENAME = 'vitalinux-confirmar-apagado-pp4mnk-es.sh'
INSTALL_PATH = HOME / '.local/bin' / FILENAME
APP_TITLE = 'Revisar cambios y apagar'
LAUNCHER_NAME = 'vitalinux-confirmar-apagado-pp4mnk.desktop'
SCAN_ROOTS = (HOME, Path('/etc'), Path('/usr/local/bin'), Path('/usr/local/sbin'),
              Path('/usr/local/share/applications'))
EXCLUDED_PARTS = {'.cache', '.git', '.thumbnails', '__pycache__'}
EXCLUDED_PREFIXES = {
    '.local/share/Trash', '.local/share/gvfs-metadata', '.local/share/recently-used.xbel',
    '.local/share/flatpak', '.config/pulse', '.config/session', '.config/sessions',
    '.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml',
    '.dbus/session-bus', '.pki/nssdb', '.Xauthority', '.ICEauthority',
    '.xsession-errors', '.xsession-errors.old', 'adjtime', 'mtab', 'resolv.conf',
    'machine-id', '.pwd.lock', 'udev/hwdb.bin',
}
BROWSER_PREFIXES = {
    '.mozilla/firefox', '.config/chromium', '.config/google-chrome', '.config/opera',
    '.config/opera-stable', '.config/slimjet', '.config/BraveSoftware',
    '.config/microsoft-edge', 'snap/firefox/common/.mozilla/firefox',
}
BROWSER_FILES = {'Bookmarks', 'user.js', 'userChrome.css', 'userContent.css'}


class Mount(NamedTuple):
    target: Path
    fs: str
    source: str
    options: str


def unescape_mount(value):
    return re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), value)


def read_mounts(path):
    try:
        lines = path.read_text(errors='surrogateescape').splitlines()
    except OSError:
        return []
    mounts = []
    for line in lines:
        left, sep, right = line.partition(' - ')
        fields = left.split()
        details = right.split()
        if sep and len(fields) >= 6 and len(details) >= 3:
            mounts.append(Mount(Path(unescape_mount(fields[4])), details[0],
                                unescape_mount(details[1]), details[2]))
    return mounts


def overlay_upper(mounts):
    for mount in reversed(mounts):
        if mount.target != Path('/'):
            continue
        if mount.fs not in {'overlay', 'overlayfs'}:
            return None
        for option in mount.options.split(','):
            name, sep, value = option.partition('=')
            if sep and name == 'upperdir' and value.startswith('/'):
                return Path(unescape_mount(value))
        return None
    return None


def persistence_message(mounts, init_mounts, boot_args):
    upper = overlay_upper(mounts)
    if upper is None:
        root = next((m for m in reversed(mounts) if m.target == Path('/')), None)
        if root and root.fs not in {'overlay', 'overlayfs', 'tmpfs', 'ramfs'}:
            return 'La raíz no usa OverlayFS. El apagado utiliza el mecanismo normal de XFCE.'
        return 'No se pudo identificar la capa de escritura de la raíz.'
    for table in (mounts, init_mounts):
        if overlay_upper(table) != upper:
            continue
        covering = [m for m in reversed(table) if m.target != Path('/')
                    and (m.target == upper or m.target in upper.parents)]
        if not covering:
            continue
        backing = max(covering, key=lambda m: len(m.target.parts))
        if backing.fs in {'tmpfs', 'ramfs'} or re.match(r'^/dev/(?:zram|ram)\d', backing.source):
            return 'La capa de escritura de la raíz está en RAM. Sus cambios se perderán al apagar o reiniciar.'
        if backing.source.startswith('/dev/') and backing.fs not in {'overlay', 'overlayfs'}:
            if re.fullmatch(r'/dev/loop\d+', backing.source):
                return ('La raíz escribe durante la sesión en un dispositivo de bucle. '
                        'No se ha verificado si el archivo de respaldo está en disco.')
            return 'La capa de escritura de la raíz está en un dispositivo de disco y se actualiza durante la sesión.'
    if 'persistent' in boot_args and 'nopersistent' not in boot_args:
        return 'El arranque solicita persistencia. No se ha podido verificar dónde se guardan los cambios de la raíz.'
    return 'No se ha podido verificar si los cambios de la raíz se conservarán tras el apagado.'


def excluded(relative, directory):
    name = relative.as_posix()
    if EXCLUDED_PARTS.intersection(relative.parts):
        return True
    if any(name == path or name.startswith(path + '/') for path in EXCLUDED_PREFIXES):
        return True
    if relative.name.endswith(('.log', '.lock', '.pid', '.tmp', '.swp', '.swo', '_history',
                               '.crdownload', '.part')):
        return True
    if any(name == path or name.startswith(path + '/') for path in BROWSER_PREFIXES):
        if {'Cache', 'Code Cache', 'GPUCache', 'cache2', 'Crash Reports', 'Crashpad'}.intersection(relative.parts):
            return True
        return not directory and relative.name not in BROWSER_FILES
    return False


def scan_changes(roots, mounted, since_ns):
    changed = set()
    skipped = 0

    def scan_error(error):
        nonlocal skipped
        if not isinstance(error, FileNotFoundError):
            skipped += 1

    for root in roots:
        try:
            root_device = root.stat().st_dev
        except FileNotFoundError:
            continue
        except OSError as error:
            scan_error(error)
            continue
        for folder, directories, files in os.walk(root, onerror=scan_error):
            folder = Path(folder)
            directory_names = set(directories)
            pending = []
            for name in directories + files:
                path = folder / name
                if path in mounted or excluded(path.relative_to(root), name in directory_names):
                    continue
                try:
                    info = path.lstat()
                except OSError as error:
                    scan_error(error)
                    continue
                if info.st_dev != root_device:
                    continue
                if stat.S_ISDIR(info.st_mode):
                    pending.append(name)
                elif (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)) and info.st_ctime_ns >= since_ns:
                    changed.add(path)
            directories[:] = pending
    return sorted(changed, key=lambda path: str(path).casefold()), skipped


def safe_text(value):
    return ''.join(char if char.isprintable() else repr(char)[1:-1] for char in value)


def preview():
    mounts = read_mounts(Path('/proc/self/mountinfo'))
    init_mounts = read_mounts(Path('/proc/1/mountinfo'))
    args = Path('/proc/cmdline').read_text().split()
    status = persistence_message(mounts, init_mounts, args)
    boot = re.search(r'^btime (\d+)$', Path('/proc/stat').read_text(), re.M)
    if boot is None:
        raise ValueError('No se pudo determinar cuándo arrancó Vitalinux.')
    paths, skipped = scan_changes(SCAN_ROOTS, {m.target for m in mounts},
                                  int(boot[1]) * 1_000_000_000)
    lines = [status, '', f'Archivos nuevos o modificados desde el arranque ({len(paths)})']
    lines.extend(safe_text(str(path)) for path in paths)
    if not paths:
        lines.append('Sin cambios detectados en las rutas revisadas.')
    if skipped:
        lines.extend(['', f'Acceso limitado a {skipped} rutas. La lista es parcial.'])
    lines.extend(['', 'Se revisan tu carpeta personal, /etc y los scripts y lanzadores locales.',
                  'Se omiten archivos automáticos habituales y montajes dentro de esas carpetas.'])
    return '\n'.join(lines)


def write_atomic(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temp = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            temp.replace(path)
        finally:
            temp.unlink(missing_ok=True)


def desktop_arg(path):
    # Desktop Entry string escaping, followed by Exec argument escaping.
    value = str(path).replace('%', '%%')
    value = re.sub(r'([\\"$`])', r'\\\1', value)
    return '"' + value.replace('\\', '\\\\') + '"'


def install(source):
    config_path = Path(os.environ.get('XDG_DATA_HOME') or HOME / '.local/share')
    launcher = config_path / 'applications' / LAUNCHER_NAME
    entry = (f'[Desktop Entry]\nType=Application\nName={APP_TITLE}\n'
             'Comment=Consulta los archivos modificados antes de apagar o reiniciar\n'
             f'Exec=/bin/sh {desktop_arg(INSTALL_PATH)}\nIcon=system-shutdown\n'
             'Terminal=false\nCategories=System;\n')
    write_atomic(INSTALL_PATH, source.read_bytes(), 0o755)
    write_atomic(launcher, entry.encode(), 0o644)
    print(f'Instalado. Busca «{APP_TITLE}» en el menú de XFCE.')


def graphical_preview():
    try:
        import gi
        gi.require_version('Gtk', '3.0')
        from gi.repository import Gtk
    except (ImportError, ValueError) as error:
        raise ValueError('Para la ventana gráfica se necesitan python3-gi y gir1.2-gtk-3.0. '
                         'Usa --preview para ver la lista en el terminal.') from error
    if not Gtk.init_check([])[0]:
        raise ValueError('Abre el lanzador desde el escritorio XFCE. '
                         'Puedes usar --preview desde un terminal.')

    session_logout = shutil.which('xfce4-session-logout')
    if session_logout is None:
        raise ValueError('No se encuentra xfce4-session-logout.')
    report = preview()
    actions = {1: '--reboot', 2: '--halt'}
    dialog = Gtk.Dialog(title=f'{APP_TITLE} · Vitalinux')
    dialog.set_default_size(760, 480)
    dialog.set_position(Gtk.WindowPosition.CENTER)
    dialog.add_button('Cancelar', Gtk.ResponseType.CANCEL)
    dialog.add_button('Reiniciar', 1)
    dialog.add_button('Apagar', 2)
    dialog.set_default_response(Gtk.ResponseType.CANCEL)
    scroller = Gtk.ScrolledWindow()
    view = Gtk.TextView()
    view.set_editable(False)
    view.set_cursor_visible(False)
    view.set_monospace(True)
    view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
    view.set_margin_start(12)
    view.set_margin_end(12)
    view.set_margin_top(12)
    view.get_buffer().set_text(report)
    scroller.add(view)
    dialog.get_content_area().pack_start(scroller, True, True, 0)
    dialog.show_all()
    choice = dialog.run()
    dialog.destroy()
    if choice in actions:
        result = subprocess.run([session_logout, actions[choice]], capture_output=True, text=True)
        if result.returncode:
            error = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR,
                                      buttons=Gtk.ButtonsType.CLOSE,
                                      text='XFCE no pudo completar la acción.')
            error.format_secondary_text(result.stderr.strip() or 'Comprueba los permisos de tu sesión.')
            error.run()
            error.destroy()
            return 1
    return 0


def main():
    parser = argparse.ArgumentParser(prog=Path(sys.argv[1]).name,
                                     description='Revisa cambios antes de apagar Vitalinux.')
    flags = parser.add_mutually_exclusive_group()
    flags.add_argument('--install', action='store_true', help='instala el lanzador para tu usuario')
    flags.add_argument('--preview', action='store_true', help='muestra la lista en el terminal')
    flags.add_argument('--uninstall', action='store_true', help='retira el lanzador de tu usuario')
    args = parser.parse_args(sys.argv[2:])
    try:
        if args.install:
            install(Path(sys.argv[1]))
        elif args.preview:
            print(preview())
        elif args.uninstall:
            config_path = Path(os.environ.get('XDG_DATA_HOME') or HOME / '.local/share')
            (config_path / 'applications' / LAUNCHER_NAME).unlink(missing_ok=True)
            INSTALL_PATH.unlink(missing_ok=True)
            print('Lanzador retirado.')
        else:
            return graphical_preview()
    except (OSError, ValueError) as error:
        print(f'Vitalinux · {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
PY
