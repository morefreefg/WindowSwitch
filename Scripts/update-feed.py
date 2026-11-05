#!/usr/bin/env python3
"""Build an appcast from published stable/RC releases and their signed metadata."""
import argparse,datetime,json,os,pathlib,re,urllib.request,xml.etree.ElementTree as ET
repository='morefreefg/WindowSwitch'
SPARKLE='http://www.andymatuschak.org/xml-namespaces/sparkle';ET.register_namespace('sparkle',SPARKLE)
def get_json(url):
    request=urllib.request.Request(url,headers={'User-Agent':'WindowSwitch-release-feed'})
    if url.startswith('https://api.github.com/') and os.environ.get('GH_TOKEN'):
        request.add_header('Authorization','Bearer '+os.environ['GH_TOKEN'])
    with urllib.request.urlopen(request,timeout=30) as response:return json.load(response)
def build(releases, metadata_loader=get_json):
    root=ET.Element('rss',{'version':'2.0'}); channel=ET.SubElement(root,'channel')
    ET.SubElement(channel,'title').text='WindowSwitch updates'
    ET.SubElement(channel,'link').text='https://github.com/'+repository
    ET.SubElement(channel,'description').text='Stable and RC updates for WindowSwitch.'
    items=[]
    for release in releases:
        tag=release.get('tag_name','')
        if release.get('draft') or not re.fullmatch(r'v\d+\.\d+\.\d+(?:-rc[.-]\d+)?',tag,re.I):continue
        asset=next((x for x in release.get('assets',[]) if x['name'].endswith('.update.json')),None)
        if not asset:continue
        metadata=metadata_loader(asset['browser_download_url'])
        expected='https://github.com/'+repository+'/releases/download/'+tag+'/'
        if metadata['version']!=tag[1:] or not metadata['url'].startswith(expected):raise ValueError('Unexpected update identity or URL')
        if not re.fullmatch(r'[A-Za-z0-9+/]{86}==',metadata['edSignature']):raise ValueError('Missing archive signature')
        if int(metadata['length'])<=0:raise ValueError('Invalid archive length')
        if release.get('prerelease') and '-rc' not in tag.lower():continue
        items.append((int(metadata['buildVersion']),release,metadata))
    for _,release,metadata in sorted(items,key=lambda row:row[0],reverse=True)[:30]:
        item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text='WindowSwitch '+metadata['version']
        ET.SubElement(item,'link').text=release['html_url']
        ET.SubElement(item,'description').text='WindowSwitch '+metadata['version']+'. View the GitHub release for details.'
        ET.SubElement(item,f'{{{SPARKLE}}}version').text=metadata['buildVersion']
        ET.SubElement(item,f'{{{SPARKLE}}}shortVersionString').text=metadata['version']
        ET.SubElement(item,f'{{{SPARKLE}}}minimumSystemVersion').text=metadata['minimumSystemVersion']
        if '-rc' in release['tag_name'].lower():ET.SubElement(item,f'{{{SPARKLE}}}channel').text='rc'
        if release.get('published_at'):
            date=datetime.datetime.fromisoformat(release['published_at'].replace('Z','+00:00'))
            ET.SubElement(item,'pubDate').text=date.strftime('%a, %d %b %Y %H:%M:%S +0000')
        ET.SubElement(item,'enclosure',{'url':metadata['url'],'length':str(metadata['length']),'type':'application/octet-stream',f'{{{SPARKLE}}}edSignature':metadata['edSignature']})
    ET.indent(root);return ET.ElementTree(root)
if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('output',type=pathlib.Path)
    args=parser.parse_args()
    releases=get_json('https://api.github.com/repos/'+repository+'/releases?per_page=100')
    args.output.mkdir(parents=True,exist_ok=True)
    feed=build(releases);feed.write(args.output/'appcast.xml',encoding='utf-8',xml_declaration=True)
    (args.output/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>WindowSwitch updates</title><a href="https://github.com/'+repository+'/releases">Download WindowSwitch</a> · <a href="appcast.xml">Update feed</a>\n')
    print('Appcast entries:',len(feed.findall('./channel/item')))
