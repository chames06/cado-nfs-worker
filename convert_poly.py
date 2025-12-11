#!/usr/bin/env python3
"""Convertisseur Msieve .fb -> CADO-NFS .poly"""
import sys
import re

def parse_msieve(content):
    data = {'n': None, 'skew': None, 'c': [], 'Y': []}
    
    for line in content.strip().split('\n'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        
        match = re.match(r'([A-Za-z]+)(\d*)\s*[:=]?\s*(-?\d+)', line)
        if match:
            key, idx, val = match.groups()
            idx = int(idx) if idx else 0
            key = key.upper()
            
            if key == 'N':
                data['n'] = val
            elif key == 'SKEW':
                data['skew'] = val
            elif key in ('A', 'C'):
                while len(data['c']) <= idx:
                    data['c'].append('0')
                data['c'][idx] = val
            elif key in ('R', 'Y'):
                while len(data['Y']) <= idx:
                    data['Y'].append('0')
                data['Y'][idx] = val
    
    return data

def to_cado(data):
    lines = []
    if data['n']:
        lines.append(f"n: {data['n']}")
    if data['skew']:
        lines.append(f"skew: {data['skew']}")
    for i, c in enumerate(data['c']):
        lines.append(f"c{i}: {c}")
    for i, y in enumerate(data['Y']):
        lines.append(f"Y{i}: {y}")
    return '\n'.join(lines)

if __name__ == '__main__':
    content = open(sys.argv[1]).read() if len(sys.argv) >= 2 else sys.stdin.read()
    result = to_cado(parse_msieve(content))
    if len(sys.argv) >= 3:
        open(sys.argv[2], 'w').write(result)
    else:
        print(result)
