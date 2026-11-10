#!/usr/bin/env python3
"""Offline checks for aws-agentic-toolkit.yaml. No AWS credentials required.
Usage: python3 validate-template.py [template.yaml]
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

USERDATA_LIMIT = 16384      # EC2 UserData, pre-base64
TEMPLATE_INLINE_LIMIT = 51200  # CloudFormation --template-body
PSEUDO = {
    "AWS::Region", "AWS::AccountId", "AWS::StackName", "AWS::StackId",
    "AWS::Partition", "AWS::URLSuffix", "AWS::NoValue",
}

failures: list[str] = []
warnings: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)
    print(f"  FAIL  {msg}")


def warn(msg: str) -> None:
    warnings.append(msg)
    print(f"  WARN  {msg}")


def ok(msg: str) -> None:
    print(f"  ok    {msg}")


class CfnLoader(yaml.SafeLoader):
    """Tolerate !Ref / !Sub / !GetAtt / !If ... as opaque nodes."""


def _cfn_tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return {f"Fn::{suffix}": loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return {f"Fn::{suffix}": loader.construct_sequence(node, deep=True)}
    return {f"Fn::{suffix}": loader.construct_mapping(node, deep=True)}


CfnLoader.add_multi_constructor("!", _cfn_tag)


def sub_refs(template_body: str) -> set[str]:
    """Names referenced by a !Sub body. ${!X} is an escape, not a reference."""
    return {
        m.group(1)
        for m in re.finditer(r"\$\{([^}!][^}]*)\}", template_body)
    }


def find_subs(node, path="", out=None):
    """Yield (path, body, varmap_keys) for every Fn::Sub in the tree."""
    if out is None:
        out = []
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "Fn::Sub":
                if isinstance(v, str):
                    out.append((path, v, set()))
                elif isinstance(v, list) and v:
                    body = v[0]
                    vmap = set(v[1].keys()) if len(v) > 1 and isinstance(v[1], dict) else set()
                    if isinstance(body, str):
                        out.append((path, body, vmap))
            find_subs(v, f"{path}.{k}", out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            find_subs(v, f"{path}[{i}]", out)
    return out


def bash_check(script: str, label: str) -> None:
    """De-substitute CFN placeholders to plausible shell, then bash -n."""
    s = re.sub(r"\$\{!([A-Za-z_][A-Za-z0-9_]*)\}", r"${\1}", script)  # ${!VAR} -> ${VAR}
    s = re.sub(r"\$\{[^}]+\}", "CFNVAL", s)                          # params -> literal
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
        fh.write(s)
        tmp = fh.name
    r = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
    if r.returncode == 0:
        ok(f"{label}: bash -n clean")
    else:
        fail(f"{label}: bash syntax error\n{r.stderr.strip()}")
    Path(tmp).unlink(missing_ok=True)


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "aws-agentic-toolkit.yaml")
    raw = path.read_text()

    print(f"== {path} ({len(raw)} bytes)")

    print("\n-- template size")
    if len(raw) > TEMPLATE_INLINE_LIMIT:
        warn(
            f"{len(raw)} B exceeds the {TEMPLATE_INLINE_LIMIT} B --template-body limit; "
            "deploy with --template-url from S3"
        )
    else:
        ok(f"{len(raw)} B fits the {TEMPLATE_INLINE_LIMIT} B inline limit")

    print("\n-- yaml")
    try:
        t = yaml.load(raw, Loader=CfnLoader)
        ok("parses")
    except yaml.YAMLError as e:
        fail(f"does not parse: {e}")
        return 1

    params = t.get("Parameters", {}) or {}
    resources = t.get("Resources", {}) or {}
    conditions = t.get("Conditions", {}) or {}
    outputs = t.get("Outputs", {}) or {}
    print(
        f"   {len(params)} parameters, {len(conditions)} conditions, "
        f"{len(resources)} resources, {len(outputs)} outputs"
    )

    # Anything a !Sub may legally name.
    known = set(params) | set(resources) | PSEUDO
    for rname, rbody in resources.items():
        if isinstance(rbody, dict):
            known.add(rname)
            known |= {f"{rname}.{a}" for a in ("Arn", "DomainEndpoint", "Data",
                                               "PrivateIp", "PublicIp", "DomainArn",
                                               "Outputs")}
    # GetAtt of any depth, e.g. Foo.Bar.Baz
    getatt_ok = re.compile(r"^[A-Za-z0-9]+\.[A-Za-z0-9.]+$")

    print("\n-- !Sub references")
    bad = 0
    for loc, body, vmap in find_subs(t):
        for ref in sub_refs(body):
            if ref in known or ref in vmap or getatt_ok.match(ref):
                continue
            fail(f"unresolved ${{{ref}}} at {loc}")
            bad += 1
    if not bad:
        ok("every ${...} resolves to a parameter, resource, GetAtt, pseudo-param or var map entry")

    print("\n-- bootstrap scripts")
    inst = resources.get("ToolkitInstance", {})
    ud = inst.get("Properties", {}).get("UserData", {})
    ud_sub = ud.get("Fn::Base64", {})
    if isinstance(ud_sub, dict):
        ud_sub = ud_sub.get("Fn::Sub", "")
    if isinstance(ud_sub, list):
        ud_sub = ud_sub[0]
    if not ud_sub:
        fail("could not extract UserData")
    else:
        n = len(ud_sub.encode())
        pct = 100 * n / USERDATA_LIMIT
        if n > USERDATA_LIMIT:
            fail(f"UserData {n}/{USERDATA_LIMIT} B - OVER by {n - USERDATA_LIMIT}")
        else:
            ok(f"UserData {n}/{USERDATA_LIMIT} B ({pct:.0f}%), headroom {USERDATA_LIMIT - n}")
        bash_check(ud_sub, "stage 1 (UserData)")

    meta = inst.get("Metadata", {}).get("EatBootstrap", {}).get("script", {})
    s2 = meta.get("Fn::Sub") if isinstance(meta, dict) else meta
    if isinstance(s2, list):
        s2 = s2[0]
    if not s2:
        fail("could not extract stage 2 from ToolkitInstance Metadata")
    else:
        ok(f"stage 2 {len(s2.encode())} B in resource Metadata (no EC2 cap applies)")
        bash_check(s2, "stage 2 (Metadata)")
        if "EAT_STAGE2_MARKER" not in s2:
            fail("stage 2 lacks EAT_STAGE2_MARKER; stage 1's truncation check will always fail")
        else:
            ok("EAT_STAGE2_MARKER present, matching stage 1's truncation check")
        # Stage 2 relies on variables that stage 1 must export.
        for v in ("SIGNAL_URL", "PROXY", "NO_PROXY_BASE"):
            if re.search(rf"\${{!?{v}\b|\${v}\b", s2) and f"export" not in ud_sub:
                warn(f"stage 2 uses ${v} but stage 1 may not export it")
        m = re.search(r"^\s*export\s+(.*)$", ud_sub, re.M)
        if m:
            ok(f"stage 1 exports handoff vars: {m.group(1).strip()}")

    print("\n-- parameter hygiene")
    body_all = raw
    for p in sorted(params):
        # Referenced via !Ref, ${p} in a Sub, or the Interface metadata.
        used = (
            re.search(rf"!Ref\s+{p}\b", body_all)
            or re.search(rf"Ref:\s*{p}\b", body_all)
            or re.search(rf"\$\{{{p}\}}", body_all)
            or re.search(rf"\b{p}\b", body_all[body_all.find("Conditions:"):] if "Conditions:" in body_all else "")
        )
        if not used:
            warn(f"parameter {p} is declared but never referenced")
    declared_in_groups = set()
    for g in (
        t.get("Metadata", {})
        .get("AWS::CloudFormation::Interface", {})
        .get("ParameterGroups", [])
        or []
    ):
        declared_in_groups |= set(g.get("Parameters", []) or [])
    missing = set(params) - declared_in_groups
    if missing:
        warn(f"not in any console parameter group (renders under 'Other'): {', '.join(sorted(missing))}")
    else:
        ok("every parameter appears in a console parameter group")

    print("\n-- AWS Marketplace")
    # ImageId must Ref a parameter of an allowed type; Marketplace swaps that
    # parameter for its own per-region SSM parameter at publish time.
    allowed_ami_types = {
        "AWS::EC2::Image::Id",
        "AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>",
        "String",
    }
    for rname, rbody in resources.items():
        if not isinstance(rbody, dict) or rbody.get("Type") != "AWS::EC2::Instance":
            continue
        img = (rbody.get("Properties") or {}).get("ImageId")
        ref = img.get("Fn::Ref") if isinstance(img, dict) else None
        if ref not in params:
            fail(f"{rname}.ImageId must !Ref a template parameter (got {img!r})")
        elif params[ref].get("Type") not in allowed_ami_types:
            fail(f"{rname}.ImageId parameter {ref} has type {params[ref].get('Type')}")
        else:
            ok(f"{rname}.ImageId -> parameter {ref} ({params[ref]['Type']})")
    # Hardcoded partitions break GovCloud/China; use ${AWS::Partition}.
    hard_arns = [i + 1 for i, line in enumerate(raw.splitlines())
                 if re.search(r"arn:aws(-[a-z]+)?:", line) and not line.lstrip().startswith("#")]
    if hard_arns:
        fail(f"hardcoded ARN partition on line(s) {hard_arns}; use arn:${{AWS::Partition}}:")
    else:
        ok("no hardcoded ARN partitions")
    # Customer-facing text must not leak seller-internal networks or hosts.
    internal = [i + 1 for i, line in enumerate(raw.splitlines())
                if re.search(r"intel\.com|10\.115\.", line)]
    if internal:
        fail(f"seller-internal hostname/CIDR on line(s) {internal}")
    else:
        ok("no seller-internal hostnames or CIDRs")
    # Marketplace forbids defaults that open ingress to the internet.
    for p, spec in params.items():
        if str(spec.get("Default", "")).strip() == "0.0.0.0/0":
            fail(f"parameter {p} defaults to 0.0.0.0/0")

    print("\n-- summary")
    if failures:
        print(f"  {len(failures)} FAILURE(S), {len(warnings)} warning(s)")
        return 1
    print(f"  all checks passed, {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
