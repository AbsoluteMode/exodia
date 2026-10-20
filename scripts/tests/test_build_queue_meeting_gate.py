import importlib.util
import unittest
from datetime import datetime, timezone, timedelta
from pathlib import Path
spec=importlib.util.spec_from_file_location('gate',Path(__file__).resolve().parents[1]/'build-queue-meeting-gate.py')
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
class GateEvidenceTests(unittest.TestCase):
    def test_fresh_clear_only(self):
        now=datetime.now(timezone.utc)
        report={'observed_at':now.isoformat(),'samples':[{'status':'clear','reason':'no_call_audio_observed'}]*3}
        self.assertEqual(gate.evaluate(report,now)[0],'clear')
        report['samples'][1]={'status':'busy','reason':'microphone_in_use'}
        self.assertEqual(gate.evaluate(report,now)[0],'busy')
    def test_unknown_never_means_clear(self):
        now=datetime.now(timezone.utc)
        report={'observed_at':now.isoformat(),'samples':[{'status':'clear','reason':'no_call_audio_observed'},{'status':'unknown','reason':'read_failed'},{'status':'clear','reason':'no_call_audio_observed'}]}
        self.assertEqual(gate.evaluate(report,now)[0],'unknown')
    def test_old_future_or_incomplete_evidence_rejected(self):
        now=datetime.now(timezone.utc)
        for offset,count in [(-6,3),(1,3),(0,2)]:
            report={'observed_at':(now+timedelta(seconds=offset)).isoformat(),'samples':[{'status':'clear','reason':'no_call_audio_observed'}]*count}
            self.assertEqual(gate.evaluate(report,now)[0],'unknown')
if __name__=='__main__':unittest.main()
