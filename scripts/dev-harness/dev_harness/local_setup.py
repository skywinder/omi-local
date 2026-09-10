"""Short terminal UX over the existing checked, owned Mac lifecycle."""

import contextlib
import io
import os
import shutil
import sys
import webbrowser

from . import cli, config, local_launcher, local_library, local_stt_watch


class SetupError(ValueError):
    pass


def frame(title, lines):
    width = max(len(title), *(len(line) for line in lines)) + 4
    border = '─' * width
    return '\n'.join(['┌' + border + '┐', '│  ' + title.ljust(width - 2) + '│',
                      '├' + border + '┤', *['│  ' + line.ljust(width - 2) + '│' for line in lines],
                      '└' + border + '┘'])


def show_frame(title, lines):
    output = frame(title, lines)
    if sys.stdout.isatty() and 'NO_COLOR' not in os.environ and os.environ.get('TERM') != 'dumb':
        output = '\033[1m' + output + '\033[0m'
    print(output)


def check(cfg):
    if not shutil.which('ngrok'):
        raise SetupError('Не найден ngrok. Запустите ./start.command для подготовки.')
    # Capture diagnostic chatter in memory; credentials are never provisioned here.
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        missing, _warnings = cli.prerequisite_report(cfg)
    if missing:
        raise SetupError('Проверка зависимостей не пройдена. Диагностика: bash scripts/local-mac.sh check')
    if not all((cfg.repo_root / 'web-local' / f).is_file() for f in ('index.html', 'style.css', 'app.js', 'player.mjs')):
        raise SetupError('Не хватает файлов веб-страницы. Восстановите копию проекта.')
    try:
        local_launcher.install_plan(cfg.repo_root)
    except local_launcher.LauncherError as error:
        raise SetupError(str(error)) from error
    return 0


def run(cfg, *, open_browser=True):
    from . import local_mac

    interactive = sys.stdin.isatty() and sys.stdout.isatty()
    repo = getattr(cfg, 'repo_root', None)
    if not interactive and (repo is None or not (repo / '.env').is_file()):
        raise SetupError('Запустите ./start.command в локальном Terminal.')
    print('Проверяем готовность…', flush=True)
    check(cfg)
    local_launcher.install(cfg.repo_root)
    cfg = config.load_config(cfg.repo_root, create_layout=True)
    # Configure remains outside redirected output: key provisioning requires a TTY.
    local_mac.configure(cfg)
    print('Запускаем сервисы…', flush=True)
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        if local_mac.up(cfg):
            raise SetupError('Запуск остановлен. Диагностика: bash scripts/local-mac.sh check')
        local_library.start(cfg)
    print()
    print('Сервисы Mac запущены. Терминал можно закрыть.')
    show_frame('ОТКРЫТЬ АУДИОТЕКУ', ['omiloc', local_library.url(cfg)])
    print('Приложение на iPhone: docs/LOCAL_SETUP.md')
    if local_stt_watch.worker_ready(cfg):
        print('Новые записи распознаются автоматически.')
    else:
        print('Для автоматического распознавания: docs/LOCAL_STT.md')
    print('Остановка: bash scripts/local-mac.sh down')
    if open_browser and interactive:
        webbrowser.open(local_library.url(cfg))
    return 0
