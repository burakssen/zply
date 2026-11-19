#!/usr/bin/env python3
"""Offline regression tests for the Phase 12 M2 CSV validator."""
import unittest

from check_phase12_capture import HEADER, validate_text


def capture(samples=(2, 4, 3), summary=None, mode='single-ordered'):
    if summary is None:
        summary = (3, 3, 2, 4, 2, 4)
    entries = []
    for index, ns in enumerate(samples):
        entries.append(row('sample', index, ns, ns, ns, ns, ns, ns, mode=mode))
    entries.append(row('summary', -1, *summary, mode=mode))
    return '\n'.join(('zig build progress', ','.join(HEADER), *entries))


def row(kind, index, life, body, p05life, p95life, p05body, p95body, mode='single-ordered'):
    values = {
        'row_type':kind,'workload':'binary_xyz_f32','mode':mode,'records':128,
        'body_bytes':1536,'list_items':0,'chunk_bytes':4096,
        'budget_bytes':1048576,'warmups':1,'rounds':3,'round':index,
        'lifecycle_ns':life,'body_ns':body,'lifecycle_p05_ns':p05life,
        'lifecycle_p95_ns':p95life,'body_p05_ns':p05body,'body_p95_ns':p95body,
        'records_per_s':100.0,'input_gbps':0.01,'list_items_per_s':0.0,
        'parser_peak_bytes':65536,'batches':1,'native_submissions':1 if mode.startswith('threaded-') else 0,
        'inline_decodes':1,'max_active':1,'digest_sum':'abcd','digest_xor':'1234',
    }
    return ','.join(str(values[k]) for k in HEADER)


class CaptureTests(unittest.TestCase):
    def test_valid_capture(self):
        self.assertEqual((1, 3), validate_text(capture()))

    def test_invalid_summary_median(self):
        with self.assertRaisesRegex(ValueError, 'bad summary'):
            validate_text(capture(summary=(4, 3, 2, 4, 2, 4)))

    def test_missing_round(self):
        text = capture().replace(row('sample',1,4,4,4,4,4,4),'')
        with self.assertRaisesRegex(ValueError, 'missing or repeated'):
            validate_text(text)

    def test_reject_body_longer_than_lifecycle(self):
        with self.assertRaisesRegex(ValueError, 'invalid timing scope'):
            validate_text(capture().replace(row('sample',0,2,2,2,2,2,2),row('sample',0,2,3,2,2,3,3)))

    def test_missing_native_tasks(self):
        text = capture(mode='threaded-ordered').replace('threaded-ordered', 'threaded-unordered')
        self.assertEqual((1,3), validate_text(text))
        text = text.replace(',1,1,1,1,abcd,', ',1,0,1,1,abcd,')
        with self.assertRaisesRegex(ValueError, 'without native tasks'):
            validate_text(text)

    def test_full_matrix_validation(self):
        with self.assertRaisesRegex(ValueError, '28'):
            validate_text(capture(), require_full_matrix=True)

    def test_duplicate_summary(self):
        data = capture()+'\n'+row('summary',-1,3,3,2,4,2,4)
        with self.assertRaisesRegex(ValueError, 'duplicate summary'):
            validate_text(data)


if __name__ == '__main__':
    unittest.main()
