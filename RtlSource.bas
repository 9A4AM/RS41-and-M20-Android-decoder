B4A=true
Group=Default Group
ModulesStructureVersion=1
Type=Class
Version=9.8
@EndOfDesignText@
'Class module: RtlSource
'rtl_tcp klijent (npr. Martinov RTL-SDR driver na Androidu) -> 288 kS/s IQ
' -> mixer fs/4 -> FIR 1 + decimacija 3  -> 96 kHz IQ -> FM diskriminator -> M20.Feed
' -> FIR 2 + decimacija 2  -> 48 kHz IQ -> FM diskriminator -> RS41.Feed
'Oba dekodera rade paralelno na istom signalu (automatsko prepoznavanje sonde).
'
'Potrebne biblioteke: Core, Network (Socket), RandomAccessFile (AsyncStreams)
'
'Upotreba (Activity ili Service):
'  Dim dec As RS41
'  Dim dec2 As M20
'  Dim src As RtlSource
'  ...
'  dec.Initialize(Me, "rs41")
'  m20.Initialize(Me, "m20")
'  aud.Initialize
'  src.Initialize(Me, "src", dec, dec2, aud)
'  src.Connect("127.0.0.1", 1234)
'  Sub src_Ready
'      src.Tune(403000000)
'  End Sub
'
'Prije Connect pokreni driver istim iqsrc:// intentom koji vec koristis
'(sample rate 288000, centralna frekvencija = f + 72000).

Sub Class_Globals
	Private mCb As Object
	Private mEv As String
	Private dec As RS41
	Private m20 As M20
	Private aud As AudioOut

	Private sock As Socket
	Private ast As AsyncStreams
	Public Connected As Boolean
	Private firstChunk As Boolean

	'--- DSP ---
	Public Const FS As Int = 288000      'sample rate prema dongleu
	Private Const DEC1 As Int = 3        '288000 / 3 = 96000 (M20: 10 uzoraka po simbolu @ 9600 baud)
	Private Const dec2 As Int = 2        '96000 / 2 = 48000 (RS41: 10 uzoraka po bitu @ 4800 baud)
	Private Const NT1 As Int = 21
	Private Const NT2 As Int = 17
	Private Const CUT1 As Double = 20000 'Hz @ 288 kHz
	Private Const CUT2 As Double = 12000 'Hz @ 96 kHz
	Private taps1(NT1) As Float
	Private taps2(NT2) As Float
	Private b1I(NT1) As Float
	Private b1Q(NT1) As Float
	Private b2I(NT2) As Float
	Private b2Q(NT2) As Float
	Private bi1, bi2 As Int
	Private cnt1, cnt2 As Int
	Private mixPhase As Int
	Private p96I, p96Q As Float
	Private p48I, p48Q As Float
	Private haveOdd As Boolean
	Private oddVal As Float

	'--- indikator signala ---
	Public SignalDb As Float = -100      'snaga u kanalu, dB u odnosu na puni opseg ADC-a (dBFS)
	Public Clipping As Boolean           'ADC je zasicen (gain pre visok)
	Private pwrAcc As Double
	Private pwrCnt As Int
	Private clipCnt, byteCnt As Int
End Sub

Public Sub Initialize(Callback As Object, EventName As String, Decoder As RS41, Decoder2 As M20, Audio As AudioOut)
	mCb = Callback
	mEv = EventName
	dec = Decoder
	m20 = Decoder2
	aud = Audio
	MakeTaps(taps1, NT1, CUT1 / FS)
	MakeTaps(taps2, NT2, CUT2 / (FS / DEC1))
End Sub

'Pozovi iz Activity_Create (Activity se moze ponovno stvoriti, objekt klase ostaje)
Public Sub SetCallback(Callback As Object)
	mCb = Callback
End Sub

'--- FIR: windowed sinc (Hamming), normaliziran na DC = 1; fc = cutoff / fs ---
Private Sub MakeTaps(t() As Float, n As Int, fc As Double)
	Dim mid As Double = (n - 1) / 2
	Dim sum As Double = 0
	Dim x, h As Double
	Dim tmp(n) As Double
	For k = 0 To n - 1
		x = k - mid
		If x = 0 Then
			h = 2 * fc
		Else
			h = Sin(2 * cPI * fc * x) / (cPI * x)
		End If
		h = h * (0.54 - 0.46 * Cos(2 * cPI * k / (n - 1)))
		tmp(k) = h
		sum = sum + h
	Next
	For k = 0 To n - 1
		t(k) = tmp(k) / sum
	Next
End Sub

'==================== veza ====================

Public Sub Connect(Host As String, Port As Int)
	Reset
	sock.Initialize("sock")
	sock.Connect(Host, Port, 5000)
End Sub

Public Sub Disconnect
	If ast.IsInitialized Then ast.Close
	If sock.IsInitialized Then sock.Close
	Connected = False
End Sub

Private Sub Reset
	bi1 = 0 : bi2 = 0
	cnt1 = 0 : cnt2 = 0
	mixPhase = 0
	p96I = 0 : p96Q = 0
	p48I = 0 : p48Q = 0
	haveOdd = False
	firstChunk = True
	pwrAcc = 0 : pwrCnt = 0 : clipCnt = 0 : byteCnt = 0
	SignalDb = -100
	Clipping = False
	For i = 0 To NT1 - 1
		b1I(i) = 0 : b1Q(i) = 0
	Next
	For i = 0 To NT2 - 1
		b2I(i) = 0 : b2Q(i) = 0
	Next
End Sub

Private Sub sock_Connected(Successful As Boolean)
	If Successful = False Then
		Log("rtl_tcp: spajanje nije uspjelo: " & LastException)
		Connected = False
		If SubExists(mCb, mEv & "_Failed") Then CallSubDelayed(mCb, mEv & "_Failed")
		Return
	End If
	ast.Initialize(sock.InputStream, sock.OutputStream, "ast")
	Connected = True
	SendCmd(0x02, FS)      'sample rate
	SendCmd(0x03, 1)       'gain mode: manual
	SendCmd(0x04, 400)     'gain 40.0 dB (u desetinkama dB) - prilagodi
	SendCmd(0x08, 0)       'RTL digitalni AGC off
	If SubExists(mCb, mEv & "_Ready") Then CallSubDelayed(mCb, mEv & "_Ready")
End Sub

Private Sub ast_Error
	Log("rtl_tcp greska: " & LastException)
	Connected = False
End Sub

Private Sub ast_Terminated
	Connected = False
	If SubExists(mCb, mEv & "_Closed") Then CallSubDelayed(mCb, mEv & "_Closed")
End Sub

'==================== rtl_tcp komande ====================
'Svaka komanda: 1 bajt cmd + 32-bitni big-endian argument.

Private Sub SendCmd(cmd As Int, value As Int)
	If Connected = False Then Return
	Dim b(5) As Byte
	b(0) = cmd
	b(1) = Bit.And(Bit.ShiftRight(value, 24), 0xFF)
	b(2) = Bit.And(Bit.ShiftRight(value, 16), 0xFF)
	b(3) = Bit.And(Bit.ShiftRight(value, 8), 0xFF)
	b(4) = Bit.And(value, 0xFF)
	ast.Write(b)
End Sub

'Frekvencija sonde u Hz. Tuner ide na f + FS/4 (= +72 kHz), pa je signal na -72 kHz od
'centra (izvan DC spike-a), a mixer ga digitalno vraca na 0.
Public Sub Tune(FreqHz As Int)
	SendCmd(0x01, FreqHz + FS / 4)
End Sub

Public Sub SetGainTenthsDb(g As Int)   'npr. 400 = 40.0 dB
	SendCmd(0x03, 1)
	SendCmd(0x04, g)
End Sub

Public Sub SetAutoGain(on As Boolean)
	If on Then SendCmd(0x03, 0) Else SendCmd(0x03, 1)
End Sub

Public Sub SetPpm(ppm As Int)          'korekcija frekvencije dongla
	SendCmd(0x05, ppm)
End Sub

Public Sub SetBiasTee(on As Boolean)
	If on Then SendCmd(0x0E, 1) Else SendCmd(0x0E, 0)
End Sub

'==================== IQ tok ====================

Private Sub ast_NewData(Buffer() As Byte)
	Dim start As Int = 0
	If firstChunk Then
		firstChunk = False
		'rtl_tcp salje 12-bajtni header: "RTL0" + tuner tip + broj gain stupnjeva
		If Buffer.Length >= 12 And Buffer(0) = 82 And Buffer(1) = 84 And Buffer(2) = 76 And Buffer(3) = 48 Then start = 12
	End If
	Dim v As Float
	Dim u As Int
	For p = start To Buffer.Length - 1
		u = Bit.And(Buffer(p), 0xFF)
		If u = 0 Or u = 255 Then clipCnt = clipCnt + 1
		byteCnt = byteCnt + 1
		v = (u - 127.5) / 128
		If haveOdd Then
			haveOdd = False
			ProcessIQ(oddVal, v)
		Else
			oddVal = v
			haveOdd = True
		End If
	Next
End Sub

Private Sub ProcessIQ(i0 As Float, q0 As Float)
	'mixer: mnozenje s j^n (pomak +fs/4) bez trigonometrije
	Dim mi, mq As Float
	Select mixPhase
		Case 0
			mi = i0 : mq = q0
		Case 1
			mi = -q0 : mq = i0
		Case 2
			mi = -i0 : mq = -q0
		Case 3
			mi = q0 : mq = -i0
	End Select
	mixPhase = Bit.And(mixPhase + 1, 3)

	'--- stupanj 1: FIR + decimacija 3 (288 -> 96 kHz) ---
	b1I(bi1) = mi
	b1Q(bi1) = mq
	bi1 = bi1 + 1
	If bi1 >= NT1 Then bi1 = 0

	cnt1 = cnt1 + 1
	If cnt1 < DEC1 Then Return
	cnt1 = 0

	Dim aI, aQ As Float
	Dim idx As Int = bi1
	For k = 0 To NT1 - 1
		aI = aI + taps1(k) * b1I(idx)
		aQ = aQ + taps1(k) * b1Q(idx)
		idx = idx + 1
		If idx >= NT1 Then idx = 0
	Next

	'mjerenje snage signala (prosjek na 0.1 s = 9600 uzoraka @ 96 kHz)
	pwrAcc = pwrAcc + aI * aI + aQ * aQ
	pwrCnt = pwrCnt + 1
	If pwrCnt >= 9600 Then
		Dim pwrMean As Double = pwrAcc / pwrCnt
		Dim dbNow As Double = 10 * Logarithm(pwrMean + 0.000000000001, 10)
		If SignalDb < -99 Then
			SignalDb = dbNow
		Else
			SignalDb = 0.6 * SignalDb + 0.4 * dbNow
		End If
		Clipping = (byteCnt > 0 And clipCnt > byteCnt * 0.005)
		pwrAcc = 0 : pwrCnt = 0 : clipCnt = 0 : byteCnt = 0
	End If

	'FM diskriminator @ 96 kHz -> M20
	Dim re As Float = aI * p96I + aQ * p96Q
	Dim im As Float = aQ * p96I - aI * p96Q
	p96I = aI
	p96Q = aQ
	m20.Feed(ATan2(im, re))

	'--- stupanj 2: FIR + decimacija 2 (96 -> 48 kHz) ---
	b2I(bi2) = aI
	b2Q(bi2) = aQ
	bi2 = bi2 + 1
	If bi2 >= NT2 Then bi2 = 0

	cnt2 = cnt2 + 1
	If cnt2 < dec2 Then Return
	cnt2 = 0

	Dim cI, cQ As Float
	idx = bi2
	For k = 0 To NT2 - 1
		cI = cI + taps2(k) * b2I(idx)
		cQ = cQ + taps2(k) * b2Q(idx)
		idx = idx + 1
		If idx >= NT2 Then idx = 0
	Next

	'FM diskriminator @ 48 kHz -> RS41
	Dim re2 As Float = cI * p48I + cQ * p48Q
	Dim im2 As Float = cQ * p48I - cI * p48Q
	p48I = cI
	p48Q = cQ
	Dim dm As Float = ATan2(im2, re2)
	dec.Feed(dm)
	If aud.Mode = 2 Then aud.Push(dm)   'zvuk: demodulirani FM audio (mod 2)
End Sub
