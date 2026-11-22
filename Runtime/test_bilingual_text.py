import io
import unittest
import wave
import torch
from bilingual_text import split_languages, english_for_tts, russian_for_tts
from silero_service import synthesize


class BilingualChecks(unittest.TestCase):
    def test_original_language_and_punctuation(self):
        self.assertEqual(split_languages('Gran Turismo 7!'), [('en', 'Gran Turismo'), ('ru', '7!')])
        self.assertEqual(split_languages('Это Gran Turismo 7 — отличная игра.'),
                         [('ru', 'Это'), ('en', 'Gran Turismo'), ('ru', '7 — отличная игра.')])
        self.assertEqual(split_languages('«Spider-Man»: Новый путь.'), [('en', '«Spider-Man»:'), ('ru', 'Новый путь.')])
        self.assertEqual(split_languages("John's car"), [('en', "John's car")])
        self.assertEqual(split_languages('Сектор A-12, выход!'), [('ru', 'Сектор'), ('en', 'A-'), ('ru', '12, выход!')])
        self.assertEqual(split_languages('Русская реплика.'), [('ru', 'Русская реплика.')])

    def test_synthesis_keeps_order_and_uses_one_wave(self):
        calls = []
        class Engine:
            def __init__(self, language): self.language = language
            def apply_tts(self, **kwargs):
                calls.append((self.language, kwargs['text'], kwargs['speaker']))
                return torch.ones(4800) * .05
        wav, duration = synthesize(Engine('ru'), torch, 'Это Gran Turismo 7. Продолжаем!', 'eugene', Engine('en'))
        self.assertEqual(calls, [('ru', 'Это', 'eugene'), ('en', 'Gran Turismo', 'en_0'), ('ru', 'семь. Продолжаем!', 'eugene')])
        self.assertAlmostEqual(duration, .3)
        with wave.open(io.BytesIO(wav)) as source:
            self.assertEqual(source.getnframes(), 14400)
            self.assertEqual(source.getframerate(), 48000)
        with self.assertRaisesRegex(ValueError, 'Английская модель'):
            synthesize(Engine('ru'), torch, 'Gran Turismo', 'eugene')

    def test_numbers_always_use_russian(self):
        for text, number in [('Gran Turismo 7', '7'), ('PlayStation 5', '5'), ('PS5', '5'), ('Project 23', '23'), ('Agent 007', '007'), ('F1 2026', '2026')]:
            pieces = split_languages(text)
            self.assertTrue(any(language == 'ru' and number in value for language, value in pieces))
            self.assertTrue(all(not any(char.isdigit() for char in value) for language, value in pieces if language == 'en'))
        self.assertEqual(split_languages('123'), [('ru', '123')])
        self.assertEqual(russian_for_tts('7'), 'семь')
        self.assertEqual(russian_for_tts('5!'), 'пять!')
        self.assertEqual(russian_for_tts('2026'), 'две тысячи двадцать шесть')
        self.assertEqual(russian_for_tts('21000'), 'двадцать одна тысяча')
        self.assertEqual(russian_for_tts('007'), 'ноль ноль семь')

if __name__ == '__main__': unittest.main()
