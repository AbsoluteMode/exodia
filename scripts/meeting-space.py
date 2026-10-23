#!/usr/bin/env python3
"""Create and edit Whytap Meeting Assistant Spaces. Metadata only; keys stay in Case/Keychain."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ID = re.compile(r'^[a-z0-9][a-z0-9_-]{0,63}$')
REF = re.compile(r'^(case|keychain|env)://[A-Za-z0-9_./-]+$')

def require_id(value):
    if not ID.fullmatch(value): raise ValueError('ID must use lowercase letters, digits, _ or - (max 64).')
    return value

def allowed_part(part):
    lower=part.lower()
    return bool(part) and part not in ['.','..','node_modules','build','dist','vendor','Pods','Library','Caches'] and not part.startswith('.') and lower not in ['credentials','secrets','id_rsa','id_ed25519','keychain','keychains'] and not any(lower.endswith(suffix) for suffix in ['.pem','.p12','.pfx','.key','.keychain-db','.env']) and 'credentials.' not in lower and 'secrets.' not in lower

def validate(space):
    if set(space) != {'version','id','name','purpose','instructions','sources'} or type(space['version']) is not int or space['version'] != 1:
        raise ValueError('Expected the version 1 Space fields; see docs/meeting-assistant.md.')
    require_id(space['id'])
    for key in ['name','purpose','instructions']:
        if not isinstance(space[key],str): raise ValueError(key+' must be text.')
    if len(space['name'])>100 or len(space['purpose'])>2000 or len(space['instructions'])>8000: raise ValueError('Space text is too long.')
    if not space['name'].strip(): raise ValueError('Space name is empty.')
    if not isinstance(space['sources'],list) or len(space['sources'])>100: raise ValueError('Expected at most 100 sources.')
    seen=set()
    for source in space['sources']:
        allowed={'id','kind','name','location','connection_ref','scope','access'}
        if not set(source)<=allowed: raise ValueError('Unknown source field.')
        require_id(source['id'])
        if source['id'] in seen: raise ValueError('Duplicate source ID.')
        seen.add(source['id'])
        if not isinstance(source['name'],str) or not source['name'].strip(): raise ValueError('Source name is empty.')
        if source['access']!='read': raise ValueError('This prototype supports read boundaries only.')
        if not isinstance(source['scope'],list) or not source['scope'] or len(source['scope'])>100 or not all(isinstance(s,str) and s.strip() for s in source['scope']):
            raise ValueError('Set at least one explicit scope.')
        if source['kind']=='repository':
            location=source.get('location','')
            if not isinstance(location,str) or not location or 'connection_ref' in source: raise ValueError('Repository requires location only.')
            if not location.startswith('/'):
                raise ValueError('Pilot repository location must be an absolute local path.')
            resolved=Path(location).resolve(); user_home=Path.home().resolve()
            if str(resolved) in ['/',str(user_home),'/System','/Library','/private','/Applications','/Users'] or resolved.name.startswith('.') or str(resolved).startswith(str(user_home/'Library')+'/') or any(str(resolved)==base or str(resolved).startswith(base+'/') for base in ['/System','/Library','/Applications','/private/etc','/private/var/db','/dev']) or any(p in ['.ssh','.aws','.gnupg'] for p in resolved.parts):
                raise ValueError('Choose a project folder, not a system, home or private application directory.')
            source['location']=str(resolved)
            if re.search(r'https://[^/]*@',location): raise ValueError('Do not embed credentials in a repository URL.')
            if any(s!='.' and (s.startswith('/') or any(not allowed_part(p) for p in s.split('/'))) for s in source['scope']): raise ValueError('Repository scopes must stay inside the repository.')
        elif source['kind']=='database':
            if not isinstance(source.get('connection_ref'),str) or not REF.fullmatch(source['connection_ref']) or 'location' in source or any(len(s)>200 for s in source['scope']):
                raise ValueError('Database requires a case://, keychain:// or env:// reference, not a connection string.')
        else: raise ValueError('Supported source kinds: repository, database.')
    if len(json.dumps(space).encode())>65536: raise ValueError('Space description is too large.')
    return space

def atomic(path,value):
    data=json.dumps(value,ensure_ascii=False,indent=2)+'\n'
    fd,name=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as f:
            f.write(data);f.flush();os.fsync(f.fileno())
        os.replace(name,path)
    finally:
        if os.path.exists(name): os.unlink(name)

def load(directory,identifier):
    path=directory/(require_id(identifier)+'.json')
    if path.is_symlink(): raise ValueError('Space files must not be symbolic links.')
    value=validate(json.loads(path.read_text()))
    if value['id']!=identifier: raise ValueError('Space ID must match filename.')
    return path,value

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path.home()/'Library/Application Support/whytap',help='Whytap metadata root; override only for isolated testing.')
    sub=parser.add_subparsers(dest='command',required=True)
    sub.add_parser('list')
    p=sub.add_parser('show');p.add_argument('space')
    p=sub.add_parser('create');p.add_argument('space');p.add_argument('--name',required=True);p.add_argument('--purpose',default='');p.add_argument('--instructions',default='')
    p=sub.add_parser('edit');p.add_argument('space');p.add_argument('--name');p.add_argument('--purpose');p.add_argument('--instructions')
    for kind in ['add-repo','add-db']:
        p=sub.add_parser(kind);p.add_argument('space');p.add_argument('--id',required=True);p.add_argument('--name',required=True);p.add_argument('--scope',action='append',required=True);p.add_argument('--replace',action='store_true')
        if kind=='add-repo':p.add_argument('location')
        else:p.add_argument('--connection-ref',required=True)
    p=sub.add_parser('remove-source');p.add_argument('space');p.add_argument('source')
    p=sub.add_parser('validate');p.add_argument('space',nargs='?')
    args=parser.parse_args()
    directory=args.root.expanduser().resolve()/'meeting-spaces'
    directory.mkdir(parents=True,exist_ok=True)
    with (directory/'.edit.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        if args.command=='list':
            result=[load(directory,p.stem)[1] for p in sorted(directory.glob('*.json'))]
            print(json.dumps(result,ensure_ascii=False,indent=2));return
        if args.command=='validate' and not args.space:
            for path in directory.glob('*.json'):load(directory,path.stem)
            print('All Space descriptions are valid.');return
        identifier=require_id(args.space)
        if args.command=='create':
            path=directory/(identifier+'.json')
            if path.exists():raise ValueError('Space already exists. Use edit.')
            if len(list(directory.glob('*.json')))>=64:raise ValueError('At most 64 Spaces are supported.')
            value={'version':1,'id':identifier,'name':args.name,'purpose':args.purpose,'instructions':args.instructions,'sources':[]}
        else:
            path,value=load(directory,identifier)
            if args.command in ['show','validate']:
                print(json.dumps(value,ensure_ascii=False,indent=2));return
            if args.command=='edit':
                for key in ['name','purpose','instructions']:
                    if getattr(args,key) is not None:value[key]=getattr(args,key)
            elif args.command in ['add-repo','add-db']:
                source={'id':require_id(args.id),'kind':'repository' if args.command=='add-repo' else 'database','name':args.name,'scope':args.scope,'access':'read'}
                if args.command=='add-repo':source['location']=args.location
                else:source['connection_ref']=args.connection_ref
                old=next((s for s in value['sources'] if s['id']==source['id']),None)
                if old and old!=source and not args.replace:raise ValueError('Source ID exists. Use --replace to edit it.')
                value['sources']=[source if s['id']==source['id'] else s for s in value['sources']]
                if old is None:value['sources'].append(source)
            elif args.command=='remove-source':
                if not any(s['id']==args.source for s in value['sources']):raise ValueError('Source ID was not found.')
                value['sources']=[s for s in value['sources'] if s['id']!=args.source]
        validate(value)
        if path.exists():atomic(path.with_suffix('.json.bak'),json.loads(path.read_text()))
        atomic(path,value)
        print(json.dumps({'space':identifier,'file':str(path),'sources':len(value['sources']),'status':'description_updated_connections_not_checked'},ensure_ascii=False))

if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,TypeError,OSError) as error:
        print('Space error: '+str(error),file=sys.stderr);sys.exit(2)
