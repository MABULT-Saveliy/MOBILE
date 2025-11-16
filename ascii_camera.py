import ctypes
import shutil
import sys
import time
from contextlib import contextmanager
from typing import NamedTuple, Optional, Sequence

import cv2
import numpy as np


ASCII_CHARS = np.asarray(list(" .'`^\",:;Il!i><~+_-?][}{1)(|\\/*tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"))
IS_WINDOWS = sys.platform.startswith("win")
MSVCRT = __import__("msvcrt") if IS_WINDOWS else None
SELECT = __import__("select") if not IS_WINDOWS else None


class ColorScheme(NamedTuple):
    name: str
    palette: Optional[Sequence[int]]


COLOR_SCHEMES = {
    "1": ColorScheme("Монохром", None),
    "2": ColorScheme("Тёплый закат", (52, 88, 124, 160, 166, 172, 178, 184, 220, 226)),
    "3": ColorScheme("Неоновая радуга", (21, 27, 33, 39, 45, 51, 93, 129, 165, 201, 198, 214, 220)),
    "4": ColorScheme("Изумрудное свечение", (22, 28, 34, 40, 46, 82, 118, 154, 190, 226)),
}

DEFAULT_SCHEME_KEY = "1"


def enable_virtual_terminal() -> None:
    if not IS_WINDOWS:
        return
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.GetStdHandle(-11)
    if handle == ctypes.c_void_p(-1).value:
        return
    mode = ctypes.c_uint32()
    if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
        return
    kernel32.SetConsoleMode(handle, mode.value | 0x0004)


@contextmanager
def raw_stdin() -> None:
    if IS_WINDOWS or not sys.stdin.isatty():
        yield
        return
    import termios
    import tty

    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


def frame_to_ascii(frame: np.ndarray, width: int, scheme: ColorScheme) -> str:
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    gray = cv2.equalizeHist(gray)
    height, original_width = gray.shape
    if original_width == 0 or height == 0:
        return ""
    char_aspect = 0.5
    resized_height = max(1, int(height / original_width * width * char_aspect))
    resized = cv2.resize(gray, (width, resized_height), interpolation=cv2.INTER_AREA)
    normalized = resized.astype(np.float32) / 255.0
    indices = (normalized * (len(ASCII_CHARS) - 1)).astype(np.uint8)
    ascii_chars = ASCII_CHARS[indices]

    if scheme.palette is None:
        return "\n".join("".join(row) for row in ascii_chars)

    palette = scheme.palette
    color_indices = (normalized * (len(palette) - 1)).astype(np.uint8)
    lines = []
    for row_chars, row_palette in zip(ascii_chars, color_indices):
        line_parts = []
        last_code: Optional[int] = None
        for char, color_idx in zip(row_chars, row_palette):
            color_code = palette[int(color_idx)]
            if color_code != last_code:
                line_parts.append(f"\033[38;5;{color_code}m{char}")
                last_code = color_code
            else:
                line_parts.append(char)
        if last_code is not None:
            line_parts.append("\033[0m")
        lines.append("".join(line_parts))

    return "\n".join(lines)


def request_permission() -> bool:
    prompt = "Разрешить доступ к веб-камере для ASCII-потока? [д/Н]: "
    try:
        response = input(prompt)
    except EOFError:
        return False
    return response.strip().lower() in {"y", "yes", "д", "да"}


def choose_color_scheme() -> ColorScheme:
    print("Выберите цветовую схему ASCII-видео:")
    for key, scheme in COLOR_SCHEMES.items():
        marker = " (по умолчанию)" if key == DEFAULT_SCHEME_KEY else ""
        print(f"  {key}. {scheme.name}{marker}")

    while True:
        try:
            raw_choice = input(f"Ваш выбор [{DEFAULT_SCHEME_KEY}]: ")
        except EOFError:
            return COLOR_SCHEMES[DEFAULT_SCHEME_KEY]
        choice = raw_choice.strip() or DEFAULT_SCHEME_KEY
        if choice in COLOR_SCHEMES:
            return COLOR_SCHEMES[choice]
        print("Пожалуйста, введите один из предложенных номеров.")


def main() -> int:
    if not request_permission():
        print("Доступ к камере отклонён пользователем.")
        return 0

    scheme = choose_color_scheme()

    enable_virtual_terminal()
    try:
        sys.stdout.reconfigure(line_buffering=False, write_through=True)
    except AttributeError:
        pass

    cap = cv2.VideoCapture(0, cv2.CAP_DSHOW)
    if not cap.isOpened():
        sys.stderr.write("Не удалось получить доступ к камере.\n")
        return 1

    sys.stdout.write("\033[2J\033[?25l")
    sys.stdout.flush()

    try:
        with raw_stdin():
            try:
                while True:
                    ret, frame = cap.read()
                    if not ret:
                        sys.stderr.write("Не удалось получить кадр.\n")
                        break

                    frame = cv2.flip(frame, 1)
                    term_width = shutil.get_terminal_size((120, 40)).columns
                    ascii_width = max(20, term_width - 1)
                    ascii_frame = frame_to_ascii(frame, ascii_width, scheme)

                    sys.stdout.write("\033[H\033[0K")
                    sys.stdout.write(
                        f"\033[1mСхема: {scheme.name} — нажмите Q или Esc для выхода.\033[0m\n"
                    )
                    sys.stdout.write(ascii_frame)
                    sys.stdout.write("\033[0m\033[J")
                    sys.stdout.flush()

                    if IS_WINDOWS and MSVCRT is not None:
                        if MSVCRT.kbhit():
                            key = MSVCRT.getwch()
                            if key in ("q", "Q", "\x1b"):
                                break
                    elif SELECT is not None:
                        dr, _, _ = SELECT.select([sys.stdin], [], [], 0)
                        if dr:
                            key = sys.stdin.read(1)
                            if key in ("q", "Q", "\x1b"):
                                break

                    time.sleep(0.02)
            except KeyboardInterrupt:
                pass
    finally:
        cap.release()
        sys.stdout.write("\033[?25h\033[0m\n")
        sys.stdout.flush()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
