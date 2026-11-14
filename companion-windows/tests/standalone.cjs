// No Tauri runtime, device port or private settings: all API calls are deferred mocks.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const Module = require('node:module');
const path = require('node:path');
const testRequire = process.env.AIMONITOR_REACT_TEST_DEPS
  ? Module.createRequire(path.resolve(process.env.AIMONITOR_REACT_TEST_DEPS, 'package.json')) : require;
const React = testRequire('react');
const {create, act} = testRequire('react-test-renderer');
const project = path.resolve(__dirname, '..');
const ts = require(project + '/node_modules/typescript');
const previews = [], actions = [];
const appearance = {matches:false, listeners:new Set(),
  addEventListener(_event,listener){this.listeners.add(listener);},
  removeEventListener(_event,listener){this.listeners.delete(listener);}};
global.window = {matchMedia:()=>appearance};
function systemTheme(dark){act(()=>{appearance.matches=dark;for(const listener of appearance.listeners)listener();});}
function deferred() { let resolve, reject; const promise = new Promise((yes,no)=>{resolve=yes;reject=no;}); return {promise,resolve,reject}; }
const api = {
  standalonePreview(mac,id) { const task={...deferred(),mac,id}; previews.push(task);return task.promise; },
  standaloneAction(mac,action,id,hash) { const task={...deferred(),mac,action,id,hash};actions.push(task);return task.promise; },
};
const filename = project + '/src/pages/Standalone.tsx';
const compiled = ts.transpileModule(fs.readFileSync(filename,'utf8'), {compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.ReactJSX,target:ts.ScriptTarget.ES2022}}).outputText;
const mod = new Module(filename,module);
mod.require=id=>id==='react'?React:id==='react/jsx-runtime'?testRequire('react/jsx-runtime'):id==='../api'?api:require(id);
mod._compile(compiled,filename);
const Standalone=mod.exports.default;
const connection=(mac='A',state='connected',protocol=1)=>({state,info:{standaloneProtocol:protocol},profile:{mac,theme:'dark',orientation:'portrait',language:'en',location:null}});
const result=(name='PREVIEW',hash='hash')=>({profile:'{}',sha256:hash,pluginId:'test',name,version:'1',origin:'https://example.org',sendsLocation:false,refreshSeconds:60});
const status=(digest='')=>({available:true,storageReady:true,enabled:!!digest,profileId:digest?'test':'',pluginVersion:'1',digest,intervalSeconds:60,state:'usb',lastSuccessAgeSeconds:null,experimental:true});
let renderer, props, checks=0;
const button=key=>renderer.root.findAllByType('button').find(n=>n.props.children===key);
const text=()=>JSON.stringify(renderer.toJSON());
async function mount(link=connection()) {previews.length=0;actions.length=0;props={t:key=>key,connection:link,plugins:[{id:'test',name:'Test',sha256:'package',settings:{}}]};await act(async()=>{renderer=create(React.createElement(Standalone,props));});}
function choose(){act(()=>renderer.root.findByProps({id:'standalone-plugin'}).props.onChange({target:{value:'test'}}));return previews.at(-1);}
function update(patch){props={...props,...patch};act(()=>renderer.update(React.createElement(Standalone,props)));}
async function finish(task,value){await act(async()=>task.resolve(value));}
function click(key){act(()=>{button(key).props.onClick();});return actions.at(-1);}
function unmount(){act(()=>renderer.unmount());}
(async()=>{
 await mount(connection('A','connected',null));assert.equal(actions.length,0);await finish(choose(),result());assert(button('standalone.install').props.disabled);checks++;unmount();
 await mount();const old=choose();update({connection:connection('B')});const latest=previews.at(-1);await finish(old,result('OLD_PREVIEW'));assert(!text().includes('OLD_PREVIEW'));await finish(latest,result('NEW_PREVIEW'));assert(text().includes('NEW_PREVIEW'));checks++;unmount();
 await mount();await finish(actions[0],status());const before=choose();update({connection:{...props.connection,profile:{...props.connection.profile,language:'de'}}});const after=previews.at(-1);await finish(before,result('OLD_CONFIG'));assert(!text().includes('OLD_CONFIG'));await finish(after,result('NEW_CONFIG'));assert(text().includes('NEW_CONFIG'));checks++;unmount();
 await mount();await finish(actions[0],status());await finish(choose(),result('OLD','old'));const installing=click('standalone.install');update({connection:{...props.connection,profile:{...props.connection.profile,language:'de'}}});await finish(previews.at(-1),result('NEW','new'));assert(button('standalone.install').props.disabled);await finish(installing,status('old'));assert(!button('standalone.install').props.disabled);assert(text().includes('standalone.changed'));checks++;unmount();
 await mount();await finish(actions[0],status());await finish(choose(),result());const installingOld=click('standalone.install');update({connection:connection('A','disconnected')});update({connection:connection('B')});const newStatus=actions.at(-1);await finish(newStatus,status('new-device'));await finish(installingOld,status('old-device'));assert(!text().includes('old-device'));assert(text().includes('new-device'));checks++;unmount();
 await mount();const initial=actions[0];const manual=click('standalone.refresh');await finish(manual,status('latest-status'));await finish(initial,status('stale-status'));assert(text().includes('latest-status'));assert(!text().includes('stale-status'));checks++;unmount();
 await mount();update({connection:{...props.connection,profile:{...props.connection.profile,theme:'system'}}});const lightPreview=choose();systemTheme(true);const darkPreview=previews.at(-1);assert.notEqual(darkPreview,lightPreview);await finish(lightPreview,result('OLD_LIGHT'));assert(!text().includes('OLD_LIGHT'));await finish(darkPreview,result('NEW_DARK'));assert(text().includes('NEW_DARK'));checks++;unmount();
 await mount();await finish(actions[0],status());const oldPreview=choose();await finish(oldPreview,result('OLD','old'));const install=click('standalone.install');await act(async()=>install.reject('standalone.changed'));assert.notEqual(previews.at(-1),oldPreview);assert(button('standalone.install').props.disabled);await finish(previews.at(-1),result('REFRESHED','new'));assert(!button('standalone.install').props.disabled);assert(text().includes('REFRESHED'));checks++;unmount();
 console.log(`${checks} standalone React capability and async-state scenarios passed`);
})().catch(error=>{console.error(error);process.exitCode=1;});
