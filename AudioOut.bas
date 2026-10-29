B4A=true
Group=Default Group
ModulesStructureVersion=1
Type=Class
Version=9.8
@EndOfDesignText@
'Class module: AudioOut
'Zvuk preko android.media.AudioTrack (JavaObject), 48 kHz, 16 bit mono.
'Mode: 0 = iskljuceno, 1 = bip kad je frame ispravan, 2 = demodulirani FM audio (uzivo)
'Bip: RS41 = 1000 Hz, M20 = 1500 Hz.
'Mod 1: track stalno radi (tisina kao jastuk), tmr odrzava razinu buffera -> bip bez kasnjenja.
'Mod 2: izravno pisanje blokova, tmr samo ispisuje dijagnostiku u Log.
'Biblioteka: JavaObject

Sub Class_Globals
	Public Mode As Int
	Private at As JavaObject
	Private isOpen As Boolean
	Private tmr As Timer
	Private wr As Long                         'ukupno upisanih uzoraka
	Private dbgN As Int
	Private Const SR As Int = 48000
	Private Const GAIN As Float = 9000
	Private Const BLOCK As Int = 960           '20 ms
	Private Const CUSHION_BEEP As Int = 1920   '40 ms - jastuk u modu Bip
	Private Const CUSHION_AUDIO As Int = 4800  '100 ms - pocetni jastuk u modu Audio
	Private buf(BLOCK * 2) As Byte
	Private silence(BLOCK * 2) As Byte         'sve nule
	Private bn As Int
	Private toneLo() As Byte
	Private toneHi() As Byte
End Sub

Public Sub Initialize
	toneLo = MakeTone(1000, 100)
	toneHi = MakeTone(1500, 100)
	tmr.Initialize("tmr", 20)
	Mode = 0
End Sub

Public Sub SetMode(m As Int)
	If m = Mode And (isOpen Or m = 0) Then Return
	Mode = m
	bn = 0
	tmr.Enabled = False
	CloseTrack
	If m <> 0 Then OpenTrack
End Sub

'kind: 0 = RS41, 1 = M20
Public Sub Beep(kind As Int)
	If Mode <> 1 Or isOpen = False Then Return
	If kind = 0 Then
		WriteBytes(toneLo, toneLo.Length)
	Else
		WriteBytes(toneHi, toneHi.Length)
	End If
End Sub

'Jedan uzorak diskriminatora (rad/uzorak) - samo u modu 2
Public Sub Push(d As Float)
	If Mode <> 2 Or isOpen = False Then Return
	Dim v As Int = d * GAIN
	If v > 30000 Then v = 30000
	If v < -30000 Then v = -30000
	buf(bn) = Bit.And(v, 0xFF)
	buf(bn + 1) = Bit.And(Bit.ShiftRight(v, 8), 0xFF)
	bn = bn + 2
	If bn >= BLOCK * 2 Then
		WriteBytes(buf, bn)     'privremeno bez odbacivanja blokova
		bn = 0
	End If
End Sub

'==================== AudioTrack ====================

Private Sub Queued As Int
	Dim h As Int = at.RunMethod("getPlaybackHeadPosition", Null)
	Return wr - h
End Sub

Private Sub OpenTrack
	If isOpen Then Return
	Dim minBuf As Int = 4096
	Try
		Dim jo As JavaObject
		jo.InitializeStatic("android.media.AudioTrack")
		'CHANNEL_OUT_MONO = 4, ENCODING_PCM_16BIT = 2
		minBuf = jo.RunMethod("getMinBufferSize", Array As Object(SR, 4, 2))
		If minBuf < 1 Then minBuf = 4096
	Catch
		Log("AudioTrack minBuf: " & LastException)
	End Try
	Dim bufSize As Int = Max(minBuf * 4, SR / 2 * 2)   'najmanje 0.5 s
	Try
		'Low-latency Builder (API 26+)
		Dim af As JavaObject
		af.InitializeNewInstance("android.media.AudioFormat$Builder", Null)
		af = af.RunMethodJO("setSampleRate", Array As Object(SR))
		af = af.RunMethodJO("setEncoding", Array As Object(2))
		af = af.RunMethodJO("setChannelMask", Array As Object(4))
		Dim aa As JavaObject
		aa.InitializeNewInstance("android.media.AudioAttributes$Builder", Null)
		aa = aa.RunMethodJO("setUsage", Array As Object(1))          'USAGE_MEDIA
		aa = aa.RunMethodJO("setContentType", Array As Object(2))    'CONTENT_TYPE_MUSIC
		Dim b As JavaObject
		b.InitializeNewInstance("android.media.AudioTrack$Builder", Null)
		b = b.RunMethodJO("setAudioFormat", Array As Object(af.RunMethod("build", Null)))
		b = b.RunMethodJO("setAudioAttributes", Array As Object(aa.RunMethod("build", Null)))
		b = b.RunMethodJO("setBufferSizeInBytes", Array As Object(bufSize))
		b = b.RunMethodJO("setTransferMode", Array As Object(1))     'MODE_STREAM
		If Mode = 1 Then b = b.RunMethodJO("setPerformanceMode", Array As Object(1)) 'LOW_LATENCY samo za bip
		at = b.RunMethodJO("build", Null)
	Catch
		Log("AudioTrack builder, fallback: " & LastException)
		Try
			at.InitializeNewInstance("android.media.AudioTrack", Array As Object(3, SR, 4, 2, bufSize, 1))
		Catch
			Log("AudioTrack: " & LastException)
			isOpen = False
			Return
		End Try
	End Try
	wr = 0
	dbgN = 0
	at.RunMethod("play", Null)
	isOpen = True
	'pocetni jastuk tisine
	Dim cush As Int = CUSHION_BEEP
	If Mode = 2 Then cush = CUSHION_AUDIO
	Do While Queued < cush
		WriteBytes(silence, BLOCK * 2)
	Loop
	tmr.Enabled = True
End Sub

Private Sub CloseTrack
	tmr.Enabled = False
	If isOpen Then
		Try
			at.RunMethod("stop", Null)
			at.RunMethod("release", Null)
		Catch
			Log("AudioTrack close: " & LastException)
		End Try
	End If
	isOpen = False
End Sub

Private Sub tmr_Tick
	If isOpen = False Then Return
	If Mode = 1 Then
		'odrzava jastuk tisine da bip ide odmah
		Dim n As Int = 0
		Do While Queued < CUSHION_BEEP And n < 5
			WriteBytes(silence, BLOCK * 2)
			n = n + 1
		Loop
	Else
		'mod 2: samo dijagnostika, svake ~sekunde
		dbgN = dbgN + 1
		If dbgN >= 50 Then
			dbgN = 0
			Log("AUD Q=" & Queued & " wr=" & wr)
		End If
	End If
End Sub

'WRITE_NON_BLOCKING = 1 : nikad ne blokira UI nit; pratimo koliko je stvarno upisano
Private Sub WriteBytes(b() As Byte, n As Int)
	If isOpen = False Then Return
	Try
		Dim r As Int = at.RunMethod("write", Array As Object(b, 0, n, 1))
		If r > 0 Then wr = wr + r / 2
	Catch
		Log("AudioTrack write: " & LastException)
	End Try
End Sub

Private Sub MakeTone(freq As Int, ms As Int) As Byte()
	Dim n As Int = SR * ms / 1000
	Dim b(n * 2) As Byte
	Dim v As Int
	Dim env As Double
	For i = 0 To n - 1
		env = 1
		If i < 240 Then env = i / 240
		If i > n - 240 Then env = (n - i) / 240
		v = Sin(2 * cPI * freq * i / SR) * 12000 * env
		b(2 * i) = Bit.And(v, 0xFF)
		b(2 * i + 1) = Bit.And(Bit.ShiftRight(v, 8), 0xFF)
	Next
	Return b
End Sub