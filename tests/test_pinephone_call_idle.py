"""Execute the fixed idle query against modem-only ObjectManager data."""
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest import mock

SOURCE=Path(__file__).parents[1]/'deploy/pinephone/openrc-call-root'
QUERY=SOURCE.read_text().split("<<'CALLSTATE'\n",1)[1].split('\nCALLSTATE',1)[0]
VOICE='org.freedesktop.ModemManager1.Modem.Voice'
CALL='org.freedesktop.ModemManager1.Call'


class CallIdleTests(unittest.TestCase):
    def query(self,states,*,owner_changed=False,missing_paths=False):
        paths=[f'/org/freedesktop/ModemManager1/Call/{index}' for index in range(len(states))]
        captured=[]
        test=self
        class Bus:
            owners=0
            def get_name_owner(self,name):
                self.owners+=1
                return ':1.new' if owner_changed and self.owners>1 else ':1.7'
            def get_object(self,owner,path):
                test.assertEqual(owner,':1.7');captured.append(path)
                if path=='/org/freedesktop/ModemManager1':
                    return SimpleNamespace(GetManagedObjects=lambda timeout:{
                        '/org/freedesktop/ModemManager1/Modem/0':{VOICE:{} if missing_paths else {'Calls':paths}}
                    })
                def get_all(interface,timeout):
                    test.assertEqual((interface,timeout),(CALL,1))
                    value=states[paths.index(path)]
                    return {} if value is None else {'State':value}
                return SimpleNamespace(GetAll=get_all)
        fake=SimpleNamespace(SystemBus=Bus,Interface=lambda obj,interface:obj)
        with mock.patch.dict(sys.modules,{'dbus':fake}):
            with self.assertRaises(SystemExit) as result:
                exec(compile(QUERY,str(SOURCE),'exec'),{})
        return result.exception.code,captured

    def test_existing_or_unknown_leaf_call_vetoes_idle(self):
        for state in [0,1,2,3,4,5,6,None]:
            with self.subTest(state=state):
                status,paths=self.query([state])
                self.assertEqual(status,75)
                self.assertTrue(paths[-1].endswith('/Call/0'))

    def test_no_calls_or_all_terminated_admit_idle(self):
        self.assertEqual(self.query([])[0],0)
        self.assertEqual(self.query([7,7])[0],0)

    def test_unknown_call_list_or_replaced_owner_never_admit(self):
        self.assertEqual(self.query([],missing_paths=True)[0],75)
        self.assertEqual(self.query([7],owner_changed=True)[0],75)


if __name__=='__main__': unittest.main()
