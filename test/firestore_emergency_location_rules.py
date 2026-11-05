"""Run against the local Firestore emulator only; never contacts live data."""
import base64, datetime, json, time, urllib.error, urllib.request
PROJECT='demo-shca-location'
BASE=f'http://127.0.0.1:8185/v1/projects/{PROJECT}/databases/(default)/documents/'
def field(v):
 if isinstance(v,bool): return {'booleanValue':v}
 if isinstance(v,str): return {'stringValue':v}
 if isinstance(v,int): return {'integerValue':str(v)}
 if isinstance(v,float): return {'doubleValue':v}
 if isinstance(v,list): return {'arrayValue':{'values':[field(x) for x in v]}}
 if isinstance(v,dict): return {'mapValue':{'fields':{k:field(x) for k,x in v.items()}}}
 raise ValueError(type(v))
def token(uid):
 enc=lambda v:base64.urlsafe_b64encode(json.dumps(v).encode()).rstrip(b'=').decode()
 return enc({'alg':'none','typ':'JWT'})+'.'+enc({'iss':f'https://securetoken.google.com/{PROJECT}','aud':PROJECT,'sub':uid,'user_id':uid,'iat':int(time.time())-1,'exp':int(time.time())+3600,'auth_time':int(time.time())-1,'firebase':{'sign_in_provider':'custom'}})+'.'
def request(path,uid='owner',values=None,mask=()):
 url=BASE+path
 if mask: url+='?'+'&'.join('updateMask.fieldPaths='+key for key in mask)
 data=None if values is None else json.dumps({'fields':{k:field(v) for k,v in values.items()}}).encode()
 req=urllib.request.Request(url,data=data,method='GET' if data is None else 'PATCH',headers={'Authorization':'Bearer '+(uid if uid=='owner' else token(uid)),'Content-Type':'application/json'})
 try:
  with urllib.request.urlopen(req,timeout=10) as response: return response.status
 except urllib.error.HTTPError as error: return error.code
checks=0
def expect(actual,want):
 global checks
 assert actual==want,(checks,actual,want)
 checks+=1
for uid,role in [('elderly','elderly'),('caregiver','caregiver'),('stranger','caregiver')]:
 expect(request('users/'+uid,values={'role':role}),200)
expect(request('care_links/caregiver_elderly',values={'elderlyId':'elderly','caregiverId':'caregiver','status':'active'}),200)
loc={'latitude':3.139,'longitude':101.6869,'recordedAt':int(time.time()*1000)-10000,'accuracyMeters':35,'source':'phone','kind':'current'}
alert={'elderlyId':'elderly','status':'active','recipientCaregiverIds':['caregiver'],'type':'manual_sos'}
expect(request('emergency_alerts/located','elderly',{**alert,'location':loc}),200)
expect(request('emergency_alerts/located','caregiver'),200)
expect(request('emergency_alerts/located','stranger'),403)
expect(request('emergency_alerts/located','caregiver',{'location':{**loc,'latitude':4}},['location']),403)
expect(request('emergency_alerts/located','elderly',{'location':{**loc,'latitude':4}},['location']),403)
expect(request('emergency_alerts/legacy','elderly',alert),200)
expect(request('emergency_alerts/legacy','caregiver',{'location':loc},['location']),403)
expect(request('emergency_alerts/legacy','elderly',{'location':loc,'status':'resolved'},['location','status']),403)
expect(request('emergency_alerts/legacy','elderly',{'location':loc},['location']),200)
expect(request('emergency_alerts/located','caregiver',{'status':'resolved','resolvedByCaregiverId':'caregiver'},['status','resolvedByCaregiverId']),200)
for index,change in enumerate([{'latitude':91},{'longitude':181},{'recordedAt':int(time.time()*1000)-86410000},{'recordedAt':int(time.time()*1000)+120000},{'accuracyMeters':-1},{'source':'other'},{'kind':'live'},{'extra':'not-permitted'}]):
 expect(request('emergency_alerts/invalid'+str(index),'elderly',{**alert,'location':{**loc,**change}}),403)
expect(request('emergency_alerts/wrong-owner','caregiver',{**alert,'location':loc}),403)
expect(request('care_links/caregiver_elderly',values={'status':'removed'},mask=['status']),200)
expect(request('emergency_alerts/located','caregiver'),403)
print(f'{checks} Firestore emulator access and location validation checks passed.')
