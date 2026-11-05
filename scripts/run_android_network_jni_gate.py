#!/usr/bin/env python3
"""Execute the exact production JNI entrypoint with only Go/string boundaries doubled.
Not an Android binary/device test; full Android packaging remains required.
"""
from pathlib import Path
import os, re, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = (ROOT / 'android/core/src/main/cpp/core.cpp').read_text()
    match = re.search(r'extern "C"\s+JNIEXPORT void JNICALL\s+Java_cc_chenx_flclash_core_Core_updateNetwork\([^}]+\}', source)
    assert match, 'production JNI target missing'
    java = Path(os.environ['JAVA_HOME'])
    with tempfile.TemporaryDirectory(prefix='yf098-jni-', dir=os.environ.get('TMPDIR')) as tmp:
        p = Path(tmp)
        harness = p / 'main.cpp'
        harness.write_text('''#include <jni.h>
#include <cstring>
#include <cstdlib>
#include "jni_helper.h"
static char seen_interface[128], seen_gateway[128];
static int calls;
char *jni_get_string(JNIEnv *, jstring value) { return reinterpret_cast<char *>(value); }
void updateNetwork(char *name, char *gateway) {
 ++calls; std::strcpy(seen_interface,name); std::strcpy(seen_gateway,gateway);
}
''' + match.group(0) + '''
int main() {
 auto target = &Java_cc_chenx_flclash_core_Core_updateNetwork;
 target(nullptr,nullptr,reinterpret_cast<jstring>(const_cast<char *>("wlan0")),reinterpret_cast<jstring>(const_cast<char *>("192.0.2.1")));
 if(calls!=1 || std::strcmp(seen_interface,"wlan0") || std::strcmp(seen_gateway,"192.0.2.1"))return 1;
 target(nullptr,nullptr,reinterpret_cast<jstring>(const_cast<char *>("")),reinterpret_cast<jstring>(const_cast<char *>("")));
 if(calls!=2 || *seen_interface || *seen_gateway)return 2;
 return 0;
}
''')
        env = os.environ.copy()
        includes = [java/'include', java/'include'/('win32' if os.name == 'nt' else 'linux'), ROOT/'android/core/src/main/cpp']
        if os.name == 'nt':
            compiler = 'G:/Android/Sdk/ndk/30.0.16248370/toolchains/llvm/prebuilt/windows-x86_64/bin/clang++.exe'
            vc = Path('G:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC/14.44.35207')
            includes += [vc/'include'] + [Path('F:/toolchains/rust-round2/sdk-headers/c/Include/10.0.26100.0')/part for part in ['ucrt','shared','um']]
            env['LIB'] = ';'.join(str(v) for v in [vc/'lib/x64',Path('F:/toolchains/rust-round2/sdk/c/um/x64'),Path('F:/toolchains/rust-round2/sdk/c/ucrt/x64')])
            flags = ['--target=x86_64-pc-windows-msvc','-fuse-ld='+str(vc/'bin/Hostx64/x64/link.exe'),'-D_DLL','-D_MT','-Xclang','--dependent-lib=msvcrt']
        else:
            compiler = shutil.which('c++'); flags = []
        binary = p/('native.exe' if os.name == 'nt' else 'native')
        command = [str(compiler),*flags,*[f'-I{x}' for x in includes],str(harness),'-o',str(binary)]
        if os.name == 'nt':
            obj = p/'main.obj'
            subprocess.run([str(compiler),*flags,*[f'-I{x}' for x in includes],'-c',str(harness),'-o',str(obj)],env=env,check=True,timeout=60)
            subprocess.run([str(vc/'bin/Hostx64/x64/link.exe'),str(obj),'/OUT:'+str(binary),'/NOLOGO'],env=env,check=True,timeout=60)
        else:
            subprocess.run(command,env=env,check=True,timeout=60)
        subprocess.run([str(binary)],check=True,timeout=15)
        # Mutate only the compiled production-target copy, never repository source.
        body = harness.read_text()
        mutation = body.replace('updateNetwork(get_string(interface_name), get_string(gateway));',
                                'updateNetwork(get_string(gateway), get_string(interface_name));')
        assert mutation != body
        harness.write_text(mutation)
        if os.name == 'nt':
            subprocess.run([str(compiler),*flags,*[f'-I{x}' for x in includes],'-c',str(harness),'-o',str(obj)],env=env,check=True,timeout=60)
            subprocess.run([str(vc/'bin/Hostx64/x64/link.exe'),str(obj),'/OUT:'+str(binary),'/NOLOGO'],env=env,check=True,timeout=60)
        else:
            subprocess.run(command,env=env,check=True,timeout=60)
        assert subprocess.run([str(binary)],timeout=15).returncode == 1, 'swapped JNI arguments mutation escaped'
        print('PASS production JNI updateNetwork method target: route + empty-network arguments; 2 exact calls; swapped-argument mutation rejected')


if __name__ == '__main__':
    main()
