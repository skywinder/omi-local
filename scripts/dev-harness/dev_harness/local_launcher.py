"""User command for the owned, loopback audio library."""

import argparse
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import webbrowser

from . import config, local_library, safety


class LauncherError(ValueError):
    pass


def install_plan(repo, *, home=None):
    home = home or Path.home()
    source = repo.resolve() / 'omiloc'
    target = home / '.local/bin/omiloc'
    if not source.is_file() or not os.access(source, os.X_OK):
        raise LauncherError('Не найден исполняемый файл omiloc в проекте.')
    if os.path.lexists(target) and not (target.is_symlink() and target.resolve() == source):
        raise LauncherError('Имя ~/.local/bin/omiloc уже занято. Существующий файл сохранён.')
    existing = shutil.which('omiloc')
    if existing and Path(existing).resolve() != source:
        raise LauncherError('В PATH уже есть другая команда omiloc. Она сохранена.')
    shell = Path(os.environ.get('SHELL', '/bin/zsh')).name
    profile = home / ('.bash_profile' if shell == 'bash' else '.zprofile')
    on_path = str(target.parent) in os.environ.get('PATH', '').split(os.pathsep)
    line = 'export PATH="$HOME/.local/bin:$PATH"'
    profile_text = profile.read_text() if profile.exists() else ''
    if not on_path and shell not in {'bash', 'zsh'}:
        raise LauncherError('Добавьте ~/.local/bin в PATH вашей оболочки и повторите установку.')
    # Check both destinations before changing either of them.
    for destination in (target.parent, profile if profile.exists() else home):
        parent = destination
        while not parent.exists():
            parent = parent.parent
        if not os.access(parent, os.W_OK):
            raise LauncherError('Нет доступа для установки команды в домашнюю папку.')
    return source, target, profile, line if not on_path and line not in profile_text.splitlines() else None


def install(repo, *, home=None):
    source, target, profile, line = install_plan(repo, home=home)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.is_symlink():
        target.symlink_to(source)
    if line:
        with profile.open('a') as stream:
            stream.write('\n# omiloc\n' + line + '\n')
    return target


def open_library(cfg):
    # This path never provisions a key, starts ngrok, or prints private settings.
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        local_library.start(cfg)
    address = local_library.url(cfg)
    print('omiloc · ' + address)
    if not webbrowser.open(address):
        print('Откройте этот адрес в браузере.')
    return 0


def main():
    parser = argparse.ArgumentParser(prog='omiloc', description='Открыть локальную аудиотеку в браузере.')
    parser.add_argument('--install', action='store_true', help='установить команду для текущего пользователя')
    args = parser.parse_args()
    try:
        repo = Path.cwd()
        if args.install:
            install(repo)
            print('Команда omiloc установлена. При необходимости откройте новый Terminal.')
        else:
            cfg = config.load_config(repo, create_layout=False)
            return open_library(cfg)
        return 0
    except (ValueError, OSError, RuntimeError, safety.SafetyError, subprocess.SubprocessError) as error:
        message = str(error) if isinstance(error, LauncherError) else (
            'Не удалось открыть аудиотеку. Из папки проекта выполните: ./start.command --check')
        print(message, file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
