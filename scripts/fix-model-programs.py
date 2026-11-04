#!/usr/bin/env python3
"""Makes the corrected model programs the app carries (see Support/ModelFix.swift).

The models are converted at half precision, and some of their normalization arithmetic doesn't fit it. This rewrites
that arithmetic in a model's program (model.mil in its .mlmodelc) to run at full precision. The weights don't change.

  scripts/fix-model-programs.py <models folder> ImageViewer/Support/ModelFixes

<models folder> has the installed models as they were converted (Models in the app's Application Support folder, if
none has been fixed yet). It prints the SHA-256 of each program before and after, for ModelFix.swift.
"""
import hashlib
import os
import re
import subprocess
import sys
import tempfile

IND = " " * 12
OP = re.compile(r'\s*tensor<fp16, (\[[^\]]*\])> ([A-Za-z0-9_]+) = ([a-z_0-9]+)\((.*)\)\[name = tensor<string, \[\]>\("([^"]*)"\)\];$')


def shapes_of(lines):
    shapes = {}
    for line in lines:
        m = re.match(r'\s*tensor<fp16, (\[[^\]]*\])> ([A-Za-z0-9_]+) = ', line)
        if m:
            shapes[m.group(2)] = m.group(1)
    return shapes


def cast(name, kind, x, shape):
    return f'{IND}tensor<{kind}, {shape}> {name} = cast(dtype = fix_to_{kind}, x = {x})[name = tensor<string, []>("{name}")];'


def with_cast_constants(lines):
    i = next(i for i, line in enumerate(lines) if 'func main<' in line)
    lines[i + 1:i + 1] = [
        f'{IND}tensor<string, []> fix_to_fp32 = const()[name = tensor<string, []>("fix_to_fp32"), val = tensor<string, []>("fp32")];',
        f'{IND}tensor<string, []> fix_to_fp16 = const()[name = tensor<string, []>("fix_to_fp16"), val = tensor<string, []>("fp16")];',
    ]
    return lines


def fix_vae(text):
    """A VAE's group norms: the mean, the squares, the variance and its square root at full precision.

    High-resolution layers have values over 256, so their squares overflow fp16; the variance is then infinite, and
    dividing by it leaves the layer all zeros. The square root fits fp16, so the division stays as it was.
    """
    lines = text.split('\n')
    shapes = shapes_of(lines)
    out, wide = [], set()
    for line in lines:
        m = OP.match(line)
        if not m or m.group(3) not in ('square', 'reduce_mean', 'add', 'sqrt'):
            out.append(line)
            continue
        shape, var, op, inner, name = m.groups()
        if op == 'square':
            x = re.fullmatch(r'x = (\w+)', inner).group(1)
            out.append(cast(f'{var}_x32', 'fp32', x, shapes[x]))
            out.append(f'{IND}tensor<fp32, {shape}> {var} = square(x = {var}_x32)[name = tensor<string, []>("{name}")];')
            wide.add(var)
        elif op == 'reduce_mean':
            axes, keep, x = re.fullmatch(r'axes = (\w+), keep_dims = (\w+), x = (\w+)', inner).groups()
            if x in wide:
                out.append(f'{IND}tensor<fp32, {shape}> {var} = reduce_mean(axes = {axes}, keep_dims = {keep}, x = {x})[name = tensor<string, []>("{name}")];')
                wide.add(var)
            else:
                out.append(cast(f'{var}_x32', 'fp32', x, shapes[x]))
                out.append(f'{IND}tensor<fp32, {shape}> {var}_m32 = reduce_mean(axes = {axes}, keep_dims = {keep}, x = {var}_x32)[name = tensor<string, []>("{var}_m32")];')
                out.append(f'{IND}tensor<fp16, {shape}> {var} = cast(dtype = fix_to_fp16, x = {var}_m32)[name = tensor<string, []>("{name}")];')
        elif op == 'add':
            g = re.fullmatch(r'x = (\w+), y = (\w+)', inner)
            if g and g.group(1) in wide:
                x, y = g.groups()
                out.append(cast(f'{var}_y32', 'fp32', y, shapes.get(y, '[]')))
                out.append(f'{IND}tensor<fp32, {shape}> {var} = add(x = {x}, y = {var}_y32)[name = tensor<string, []>("{name}")];')
                wide.add(var)
            else:
                out.append(line)
        else:  # sqrt
            x = re.fullmatch(r'x = (\w+)', inner).group(1)
            if x in wide:
                out.append(f'{IND}tensor<fp32, {shape}> {var}_s32 = sqrt(x = {x})[name = tensor<string, []>("{var}_s32")];')
                out.append(f'{IND}tensor<fp16, {shape}> {var} = cast(dtype = fix_to_fp16, x = {var}_s32)[name = tensor<string, []>("{name}")];')
            else:
                out.append(line)
    return '\n'.join(with_cast_constants(out))


def fix_restormer(text):
    """Restormer's layer norms and attention at full precision: from each abs, pow and reduce_* onward, and back to
    fp16 after each softmax and each layer norm's division.

    Its attention sums 147,456 squares, which overflows fp16, and the normalized values' products (about 1/384 squared)
    are below fp16's normal range. On a CPU that gives wrong colors and ringing.
    """
    lines = text.split('\n')
    shapes = shapes_of(lines)
    out, wide, subs, casts = [], set(), set(), 0
    for line in lines:
        m = OP.match(line)
        if not m or m.group(3) == 'const':
            out.append(line)
            continue
        shape, var, op, inner, name = m.groups()
        operands = [v for _, v in re.findall(r'(\w+) = (\w+)', inner) if v in shapes]
        if not (op in ('abs', 'pow', 'reduce_sum', 'reduce_mean') or any(v in wide for v in operands)):
            out.append(line)
            continue
        new = inner
        for v in sorted(set(operands)):
            if v not in wide:
                casts += 1
                c = f'{v}__c{casts}'
                out.append(cast(c, 'fp32', v, shapes[v]))
                new = re.sub(rf'= {v}\b', f'= {c}', new)
        x = re.search(r'\bx = (\w+)', inner).group(1)
        if op == 'softmax' or (op == 'real_div' and x in subs):
            out.append(f'{IND}tensor<fp32, {shape}> {var}__w = {op}({new})[name = tensor<string, []>("{name}__w")];')
            out.append(f'{IND}tensor<fp16, {shape}> {var} = cast(dtype = fix_to_fp16, x = {var}__w)[name = tensor<string, []>("{name}")];')
        else:
            out.append(f'{IND}tensor<fp32, {shape}> {var} = {op}({new})[name = tensor<string, []>("{name}")];')
            wide.add(var)
        if op == 'sub':
            subs.add(var)
    return '\n'.join(with_cast_constants(out))


PROGRAMS = [
    ('vaeDecoder', 'VAEDecoder-fixed.mil', 'StableDiffusionInpainting/VAEDecoder.mlmodelc', fix_vae),
    ('vaeEncoder', 'VAEEncoder-fixed.mil', 'StableDiffusionInpainting/VAEEncoder.mlmodelc', fix_vae),
    ('focus', 'Focus-fixed.mil', 'Focus/Focus.mlmodelc', fix_restormer),
    ('shake', 'Shake-fixed.mil', 'Shake/Shake.mlmodelc', fix_restormer),
]


def main():
    models, output = sys.argv[1], sys.argv[2]
    os.makedirs(output, exist_ok=True)
    for label, resource, path, fix in PROGRAMS:
        original = open(os.path.join(models, path, 'model.mil'), 'rb').read()
        fixed = fix(original.decode()).encode()
        with tempfile.NamedTemporaryFile() as plain:
            plain.write(fixed)
            plain.flush()
            target = os.path.join(output, resource + '.lzfse')
            subprocess.run(['/usr/bin/compression_tool', '-encode', '-a', 'lzfse', '-i', plain.name, '-o', target], check=True)
        print(f'{label}: shipped {hashlib.sha256(original).hexdigest()} fixed {hashlib.sha256(fixed).hexdigest()} ({os.path.getsize(target)} bytes)')


if __name__ == '__main__':
    main()
