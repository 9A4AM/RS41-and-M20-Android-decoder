B4A=true
Group=Default Group
ModulesStructureVersion=1
Type=Service
Version=13.4
@EndOfDesignText@
'Service module: DecSvc
'Drzi dekodere, RTL vezu i zvuk. Radi kao foreground servis dok traje dekodiranje.
'Biblioteke: Core, Phone

#Region Service Attributes
	#StartAtBoot: False
#End Region

Sub Process_Globals
	Public dec As RS41
	Public m20 As M20
	Public src As RtlSource
	Public aud As AudioOut
	Public Ready As Boolean
	Public Running As Boolean
	Public statusEn, statusHr As String
	Public Freq As Int = 403000000
	Public GainDb As Double = 40
	Public Ppm As Int
	Private tmr As Timer
	Private wl As PhoneWakeState
	Private bgOn As Boolean
	Private waiting, connecting As Boolean
	Private attempts As Int
	Private Const DRIVER_PORT As Int = 1234
	Private Const MAX_ATTEMPTS As Int = 60    'driver je u prvom planu dok korisnik potvrdjuje USB dozvolu
End Sub

Sub Service_Create
	Service.AutomaticForegroundMode = Service.AUTOMATIC_FOREGROUND_NEVER
	tmr.Initialize("tmr", 1000)
	aud.Initialize
	dec.Initialize(Me, "rs41")
	m20.Initialize(Me, "m20")
	src.Initialize(Me, "src", dec, m20, aud)
	statusEn = "Not connected"
	statusHr = "Nije spojeno"
	Running = False
	Ready = True
End Sub

Sub Service_Start (StartingIntent As Intent)
End Sub

Sub Service_Destroy
	Ready = False
End Sub

'==================== pozadina ====================

Private Sub AcquireBackground
	If bgOn Then Return
	bgOn = True
	wl.PartialLock
	Dim n As Notification
	n.Initialize2(n.IMPORTANCE_LOW)
	n.Icon = "icon"
	n.Sound = False
	n.Vibrate = False
	n.SetInfo("RS41 / M20  9A4AM", "Dekodiranje radi u pozadini", Main)
	Service.StartForeground(1, n)
End Sub

Private Sub ReleaseBackground
	If bgOn = False Then Return
	bgOn = False
	wl.ReleasePartialLock
	Service.StopForeground(1)
End Sub

'==================== UI ====================

Private Sub UiNotify
	If IsPaused(Main) = False Then CallSub(Main, "UiRefresh")
End Sub

Private Sub SetStatus(en As String, hr As String)
	statusEn = en
	statusHr = hr
	UiNotify
End Sub

'==================== naredbe iz Maina ====================

'Main je vec pokrenuo driver (iqsrc intent); ovdje se samo spajamo s ponavljanjem
Public Sub BeginConnect
	tmr.Enabled = False
	src.Disconnect
	dec.ResetAll
	m20.ResetAll
	attempts = 0
	connecting = False
	waiting = True
	Running = True
	AcquireBackground
	SetStatus("Starting driver...", "Pokre{c}em driver...")
	tmr.Enabled = True
End Sub

Public Sub ApplySettings
	dec.ResetAll
	m20.ResetAll
	src.SetGainTenthsDb(Round(GainDb * 10))
	src.SetPpm(Ppm)
	src.Tune(Freq)
	Dim f As String = NumberFormat(Freq / 1000000, 1, 3)
	SetStatus("Listening on " & f & " MHz", "Slu{s}am " & f & " MHz")
End Sub

Public Sub StopDec
	waiting = False
	connecting = False
	Running = False
	tmr.Enabled = False
	src.Disconnect
	ReleaseBackground
	SetStatus("Stopped", "Zaustavljeno")
End Sub

'Potpuni izlaz iz aplikacije
Public Sub Shutdown
	waiting = False
	connecting = False
	Running = False
	tmr.Enabled = False
	src.Disconnect
	aud.SetMode(0)
	ReleaseBackground
	Ready = False
	StopService(Me)
End Sub

'==================== spajanje ====================

Sub tmr_Tick
	If waiting = False Then
		tmr.Enabled = False
		Return
	End If
	If connecting Then Return
	attempts = attempts + 1
	If attempts > MAX_ATTEMPTS Then
		waiting = False
		Running = False
		tmr.Enabled = False
		ReleaseBackground
		SetStatus("RTL-SDR not found. Press Start.", "RTL-SDR nije prona{d}en. Pritisni Start.")
		Return
	End If
	connecting = True
	SetStatus("Connecting (" & attempts & "/" & MAX_ATTEMPTS & ")...", "Spajam se (" & attempts & "/" & MAX_ATTEMPTS & ")...")
	src.Connect("127.0.0.1", DRIVER_PORT)
End Sub

'==================== eventi iz klasa ====================

Sub src_Ready
	waiting = False
	connecting = False
	tmr.Enabled = False
	ApplySettings
End Sub

Sub src_Failed
	connecting = False   'tmr_Tick ce pokusati ponovno
End Sub

Sub src_Closed
	connecting = False
	If waiting Or Running = False Then Return
	Running = False
	ReleaseBackground
	SetStatus("Connection closed", "Veza zatvorena")
End Sub

Sub rs41_Frame(ok As Int)
	If ok > 0 Then aud.Beep(0)
	UiNotify
End Sub

Sub m20_Frame(ok As Boolean)
	If ok Then aud.Beep(1)
	UiNotify
End Sub