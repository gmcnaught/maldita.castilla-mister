import subprocess,glob
W,H=288,216
from collections import Counter
c=Counter(); mx=(0,None)
for f in sorted(glob.glob('ab_prefix/*.png')):
    d=subprocess.run(['magick','identify','-format','%w %h',f],capture_output=True,text=True).stdout.split()
    if [int(x) for x in d]!=[W,H]:
        c['non-native %sx%s'%(d[0],d[1])]+=1; continue
    raw=subprocess.run(['magick',f,'-depth','8','rgb:-'],capture_output=True).stdout
    r0=raw[0:W*3]
    nz=sum(1 for i in range(0,len(r0),3) if r0[i:i+3]!=b'\x00\x00\x00')
    c[nz]+=1
    if nz>mx[0]: mx=(nz,f)
print("row0 non-black pixel counts across pre-fix frames:", dict(c))
print("max:",mx)
