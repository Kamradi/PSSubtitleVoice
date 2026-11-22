"""Preserve written text; route Latin spans to English and Cyrillic spans to Russian."""
import re

# Latin words use English; digits always remain in Russian, even in brand names.
# Keep a model-name hyphen with the Latin prefix so A-12 is not read as minus 12.
ENGLISH = re.compile(r"[A-Za-z]+(?:['’\-][A-Za-z]+)*(?:[ \t]+[A-Za-z]+(?:['’\-][A-Za-z]+)*)*(?:-(?=[0-9]))?")
CONTENT = re.compile(r'[A-Za-zА-Яа-яЁё0-9]')

ONES_RU = ['ноль', 'один', 'два', 'три', 'четыре', 'пять', 'шесть', 'семь', 'восемь', 'девять',
           'десять', 'одиннадцать', 'двенадцать', 'тринадцать', 'четырнадцать', 'пятнадцать', 'шестнадцать', 'семнадцать', 'восемнадцать', 'девятнадцать']
TENS_RU = ['', '', 'двадцать', 'тридцать', 'сорок', 'пятьдесят', 'шестьдесят', 'семьдесят', 'восемьдесят', 'девяносто']
HUNDREDS_RU = ['', 'сто', 'двести', 'триста', 'четыреста', 'пятьсот', 'шестьсот', 'семьсот', 'восемьсот', 'девятьсот']

def russian_number(digits):
    if len(digits) > 12 or (len(digits) > 1 and digits.startswith('0')):
        return ' '.join(ONES_RU[int(digit)] for digit in digits)
    value = int(digits)
    if value == 0: return ONES_RU[0]
    scales = [('', '', ''), ('тысяча', 'тысячи', 'тысяч'), ('миллион', 'миллиона', 'миллионов'), ('миллиард', 'миллиарда', 'миллиардов')]
    groups = []
    for scale, forms in enumerate(scales):
        group = value % 1000; value //= 1000
        if not group: continue
        words = [HUNDREDS_RU[group // 100]] if group >= 100 else []
        rest = group % 100
        if rest >= 20:
            words.append(TENS_RU[rest // 10]); rest %= 10
        if rest:
            words.append(('одна' if rest == 1 else 'две') if scale == 1 and rest in (1, 2) else ONES_RU[rest])
        if scale:
            index = 2 if 11 <= group % 100 <= 14 else 0 if group % 10 == 1 else 1 if 2 <= group % 10 <= 4 else 2
            words.append(forms[index])
        groups.append(' '.join(words))
    return ' '.join(reversed(groups))

def russian_for_tts(text):
    value = re.sub(r'[0-9]+', lambda match: ' ' + russian_number(match.group()) + ' ', text)
    value = re.sub(r'\s+', ' ', value).strip()
    return re.sub(r'\s+([.,!?;:])', r'\1', value)

def english_for_tts(text):
    value = re.sub(r'\s+', ' ', text.replace('’', "'")).strip()
    return re.sub(r'\s+([.,!?;:])', r'\1', value)


def split_languages(text):
    parts = []
    pending = ''
    end = 0
    def append(language, value):
        nonlocal pending
        if not value: return
        if not CONTENT.search(value):
            if parts: parts[-1] = (parts[-1][0], parts[-1][1] + value)
            else: pending += value
            return
        if parts:
            closing = re.match(r'''^(\s*[»”"')\].,;:!?]+\s*)''', value)
            if closing:
                parts[-1] = (parts[-1][0], parts[-1][1] + closing.group())
                value = value[closing.end():]
        parts.append((language, pending + value))
        pending = ''
    for match in ENGLISH.finditer(text):
        append('ru', text[end:match.start()])
        append('en', match.group())
        end = match.end()
    append('ru', text[end:])
    return [(language, value.strip()) for language, value in parts if value.strip()]
