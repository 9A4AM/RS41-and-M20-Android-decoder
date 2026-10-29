B4A=true
Group=Default Group
ModulesStructureVersion=1
Type=Class
Version=9.8
@EndOfDesignText@
'Class module: M20
'Port of rs1729 mXX.c (Meteomodem M20) -> B4A.
'Ulaz: FM-diskriminator uzorci na 96 kHz (10 uzoraka po simbolu, 9600 baud), rad/uzorak.
'Svaki podatkovni bit = 2 simbola; bit se dobije usporedbom drugog i prvog simbola (m),
'a zatim diferencijalno: bit = 1 ako je m jednak prethodnom m (kao u mXX.c).
'Nema ECC-a, samo M10 checksum (CRC-slican, 16 bit).
'
'Upotreba:
'  Dim m20 As M20
'  m20.Initialize(Me, "m20")         'event: Sub m20_Frame(ok As Boolean)
'  m20.Feed(sample)                  '96 kHz diskriminator

Sub Class_Globals
	Private mCallback As Object
	Private mEvent As String

	Private Const SPS As Int = 10
	Private Const HDR_BITS As Int = 32
	Private Const MEAN_WIN As Int = 320      'HDR_BITS * SPS
	Private Const HDR_MAX_ERR As Int = 2
	Private Const MA_LEN As Int = 8
	Private Const T_LIMIT As Float = 1.0
	Private Const T_LEAK As Float = 0.94
	Private Const MAX_FRAME As Int = 170
	Private Const GPS_UTC_LEAP As Int = 18
	Private HDR As Int                       '0x99994C99 (raw header, 32 simbola)

	'--- javni rezultati ---
	Public Id As String
	Public HaveId, HavePos, HaveTime As Boolean
	Public Lat, Lon, Alt As Double
	Public Vh, Vd, Vv As Double
	Public Week, FrameCnt As Int
	Public HH, MM, SS As Int
	Public FramesOk, FramesBad As Int
	Public Eye As Float
	Public LastOk As Long                    'DateTime.Now zadnjeg ispravnog framea

	'--- sync ---
	Private Const ST_SEARCH As Int = 0
	Private Const ST_SETTLE As Int = 1
	Private Const ST_CAPTURE As Int = 2
	Private state As Int
	Private ph As Int
	Private ma(MA_LEN) As Float
	Private maI As Int
	Private maSum As Float
	Private hist(8) As Float
	Private histI As Int
	Private tacc As Float
	Private ring(MEAN_WIN) As Float
	Private ringI As Int
	Private ringSum As Float
	Private sr(SPS) As Int
	Private dist(SPS) As Int
	Private settleK, pol As Int
	Private thrS, eyeS As Float
	Private wait As Int
	Private raw(MAX_FRAME) As Int
	Private nBytes, frameLen, bitCnt, cur As Int
	Private symHalf As Int
	Private s1 As Float
	Private mPrev As Int
	Private firstBit As Boolean
End Sub

Public Sub Initialize(Callback As Object, EventName As String)
	mCallback = Callback
	mEvent = EventName
	HDR = Bit.Or(Bit.ShiftLeft(0x9999, 16), 0x4C99)
	Reset
End Sub

Public Sub SetCallback(Callback As Object)
	mCallback = Callback
End Sub

'Brisanje telemetrije i brojaca (npr. nakon promjene frekvencije)
Public Sub ResetAll
	Reset
	Id = ""
	HaveId = False : HavePos = False : HaveTime = False
	Lat = 0 : Lon = 0 : Alt = 0
	Vh = 0 : Vd = 0 : Vv = 0
	Week = 0 : FrameCnt = 0
	HH = 0 : MM = 0 : SS = 0
	FramesOk = 0 : FramesBad = 0
	Eye = 0
	LastOk = 0
End Sub

Public Sub Reset
	state = ST_SEARCH
	ph = 0
	maI = 0 : maSum = 0
	ringI = 0 : ringSum = 0
	histI = 0 : tacc = 0
	For i = 0 To MA_LEN - 1 : ma(i) = 0 : Next
	For i = 0 To 7 : hist(i) = 0 : Next
	For i = 0 To MEAN_WIN - 1 : ring(i) = 0 : Next
	ClearSr
End Sub

Private Sub ClearSr
	For i = 0 To SPS - 1
		sr(i) = 0
	Next
End Sub

'==================== checksum (M10/M20) ====================

Private Sub UpdateCheck(c As Int, b As Int) As Int
	Dim c1, t6, t7, t, s, c0 As Int
	c1 = Bit.And(c, 0xFF)
	'B
	b = Bit.Or(Bit.ShiftRight(b, 1), Bit.ShiftLeft(Bit.And(b, 1), 7))
	b = Bit.Xor(b, Bit.And(Bit.ShiftRight(b, 2), 0xFF))
	'A1
	t6 = Bit.Xor(Bit.Xor(Bit.And(c, 1), Bit.And(Bit.ShiftRight(c, 2), 1)), Bit.And(Bit.ShiftRight(c, 4), 1))
	t7 = Bit.Xor(Bit.Xor(Bit.And(Bit.ShiftRight(c, 1), 1), Bit.And(Bit.ShiftRight(c, 3), 1)), Bit.And(Bit.ShiftRight(c, 5), 1))
	t = Bit.Or(Bit.Or(Bit.And(c, 0x3F), Bit.ShiftLeft(t6, 6)), Bit.ShiftLeft(t7, 7))
	'A2
	s = Bit.And(Bit.ShiftRight(c, 7), 0xFF)
	s = Bit.Xor(s, Bit.And(Bit.ShiftRight(s, 2), 0xFF))
	c0 = Bit.Xor(Bit.Xor(b, t), s)
	Return Bit.And(Bit.Or(Bit.ShiftLeft(c1, 8), c0), 0xFFFF)
End Sub

'==================== frame -> telemetrija ====================

Private Sub Be16s(f() As Int, p As Int) As Int
	Dim v As Int = Bit.Or(Bit.ShiftLeft(f(p), 8), f(p + 1))
	If v > 32767 Then v = v - 65536
	Return v
End Sub

Private Sub Be32s(f() As Int, p As Int) As Int
	Return Bit.Or(Bit.Or(Bit.ShiftLeft(f(p), 24), Bit.ShiftLeft(f(p + 1), 16)), Bit.Or(Bit.ShiftLeft(f(p + 2), 8), f(p + 3)))
End Sub

'f = bajtovi framea (f(0) = duljina 0x45, f(1) = 0x20), n = broj bajtova. Vraca True ako je frame ispravan.
Public Sub DecodeFrame(f() As Int, n As Int) As Boolean
	Dim flen As Int = f(0)
	If n < flen + 1 Or flen < 0x43 Then
		FramesBad = FramesBad + 1
		Return False
	End If

	'checksum framea: bajtovi 0..flen-2, spremljen na flen-1..flen
	Dim pc As Int = flen - 1
	Dim cs1 As Int = Bit.Or(Bit.ShiftLeft(f(pc), 8), f(pc + 1))
	Dim cs As Int = 0
	For i = 0 To pc - 1
		cs = UpdateCheck(cs, f(i))
	Next
	If cs <> cs1 Or f(1) <> 0x20 Then
		FramesBad = FramesBad + 1
		Return False
	End If

	'GPS tjedan i vrijeme (TOW u sekundama, 3 bajta)
	Dim tow As Int = Bit.Or(Bit.Or(Bit.ShiftLeft(f(0x0F), 16), Bit.ShiftLeft(f(0x10), 8)), f(0x11))
	Dim day As Int = tow / 86400
	Dim wk As Int = Bit.Or(Bit.ShiftLeft(f(0x1A), 8), f(0x1B))
	If day > 6 Or wk > 4000 Then
		FramesBad = FramesBad + 1
		Return False
	End If
	If wk < 1304 Then wk = wk + 1024

	'pozicija
	Dim la As Double = Be32s(f, 0x1C) / 1000000
	Dim lo As Double = Be32s(f, 0x20) / 1000000
	Dim al As Double = Bit.Or(Bit.Or(Bit.ShiftLeft(f(0x08), 16), Bit.ShiftLeft(f(0x09), 8)), f(0x0A)) / 100
	If Abs(la) > 90 Or Abs(lo) > 180 Or al < -1000 Or al > 80000 Then
		FramesBad = FramesBad + 1
		Return False
	End If

	'brzine (E, N, U) u cm/s
	Dim vE As Double = Be16s(f, 0x0B) / 100
	Dim vN As Double = Be16s(f, 0x0D) / 100
	Dim vU As Double = Be16s(f, 0x18) / 100
	Dim dirD As Double = ATan2(vE, vN) * 180 / cPI
	If dirD < 0 Then dirD = dirD + 360

	'serijski broj
	Dim sn24 As Int = Bit.Or(Bit.Or(Bit.ShiftLeft(f(0x14), 16), Bit.ShiftLeft(f(0x13), 8)), f(0x12))
	Dim ym As Int = Bit.And(sn24, 0x7F)
	Dim yy As Int = ym / 12
	Dim mo As Int = (ym Mod 12) + 1
	Dim a As String = yy & NumberFormat2(mo, 2, 0, 0, False)
	If a.Length > 3 Then a = a.SubString2(0, 3)
	Dim subN As Int = Bit.And(Bit.ShiftRight(sn24, 7), 7) + 1
	Dim hiBit As Int = Bit.And(Bit.ShiftRight(sn24, 23), 1)
	Dim serial As Int = Bit.And(Bit.ShiftRight(sn24, 10), 0x1FFF)
	Dim snStr As String = a & "-" & subN & "-" & hiBit & NumberFormat2(serial, 4, 0, 0, False)
	If sn24 = 0 Then snStr = "000-0-00000"

	'sve provjereno - upisi rezultate
	Week = wk
	Dim sec As Int = (tow Mod 86400) - GPS_UTC_LEAP
	If sec < 0 Then sec = sec + 86400
	HH = sec / 3600
	MM = (sec Mod 3600) / 60
	SS = sec Mod 60
	HaveTime = True
	Lat = la : Lon = lo : Alt = al
	Vh = Sqrt(vE * vE + vN * vN)
	Vd = dirD
	Vv = vU
	HavePos = True
	FrameCnt = f(0x15)
	Id = snStr
	HaveId = True
	FramesOk = FramesOk + 1
	LastOk = DateTime.Now
	Return True
End Sub

'==================== bit sync + hvatanje framea ====================

Private Sub Popcount(v As Int) As Int
	v = v - Bit.And(Bit.UnsignedShiftRight(v, 1), 0x55555555)
	v = Bit.And(v, 0x33333333) + Bit.And(Bit.UnsignedShiftRight(v, 2), 0x33333333)
	v = Bit.And(v + Bit.UnsignedShiftRight(v, 4), 0x0F0F0F0F)
	v = v + Bit.UnsignedShiftRight(v, 8)
	v = v + Bit.UnsignedShiftRight(v, 16)
	Return Bit.And(v, 0x3F)
End Sub

Private Sub Back(k As Int) As Float
	Return hist(Bit.And(histI - 1 - k, 7))
End Sub

Public Sub FeedBlock(d() As Float, count As Int)
	For i = 0 To count - 1
		Feed(d(i))
	Next
End Sub

Public Sub Feed(dv As Float)
	'pomicni prosjek diskriminatora
	maSum = maSum + dv - ma(maI)
	ma(maI) = dv
	maI = maI + 1
	If maI >= MA_LEN Then maI = 0
	Dim s As Float = maSum / MA_LEN

	'srednja vrijednost preko duljine headera = prag
	ringSum = ringSum + s - ring(ringI)
	ring(ringI) = s
	ringI = ringI + 1
	If ringI >= MEAN_WIN Then ringI = 0
	Dim thr As Float = ringSum / MEAN_WIN

	hist(histI) = s
	histI = Bit.And(histI + 1, 7)

	Dim p As Int = ph
	ph = ph + 1
	If ph >= SPS Then ph = 0

	Dim b As Int = 0
	If s > thr Then b = 1

	Select state
		Case ST_SEARCH
			sr(p) = Bit.Or(Bit.ShiftLeft(sr(p), 1), b)
			Dim dn As Int = Popcount(Bit.Xor(sr(p), HDR))
			If dn <= HDR_MAX_ERR Or HDR_BITS - dn <= HDR_MAX_ERR Then
				If dn > HDR_BITS / 2 Then pol = 1 Else pol = 0
				settleK = 0
				If pol = 1 Then dist(0) = HDR_BITS - dn Else dist(0) = dn
				state = ST_SETTLE
			End If

		Case ST_SETTLE
			sr(p) = Bit.Or(Bit.ShiftLeft(sr(p), 1), b)
			settleK = settleK + 1
			Dim dd As Int = Popcount(Bit.Xor(sr(p), HDR))
			If pol = 1 Then dd = HDR_BITS - dd
			dist(settleK) = dd
			If settleK >= SPS - 1 Then
				Dim best As Int = 99
				For k = 0 To SPS - 1
					If dist(k) < best Then best = dist(k)
				Next
				Dim lo, hi As Int
				lo = -1 : hi = -1
				For k = 0 To SPS - 1
					If dist(k) <= best + 1 Then
						If lo < 0 Then lo = k
						hi = k
					End If
				Next
				Dim j As Int = (lo + hi) / 2
				wait = j + 1 + 3
				tacc = 0

				'prag iz samog headera: sredina izmedju "high" i "low" simbola
				Dim sumH, sumL As Float
				Dim nh, nl As Int
				Dim bk, idx, hb As Int
				For k = 0 To HDR_BITS - 1
					bk = (SPS - 1 - j) + SPS * k
					idx = ringI - 1 - bk
					If idx < 0 Then idx = idx + MEAN_WIN
					hb = Bit.And(Bit.ShiftRight(HDR, k), 1)
					hb = Bit.Xor(hb, pol)
					If hb = 1 Then
						sumH = sumH + ring(idx) : nh = nh + 1
					Else
						sumL = sumL + ring(idx) : nl = nl + 1
					End If
				Next
				If nh > 0 And nl > 0 Then
					sumH = sumH / nh : sumL = sumL / nl
					thrS = 0.5 * (sumH + sumL)
					eyeS = sumH - sumL
				Else
					thrS = thr
					eyeS = 0
				End If

				nBytes = 0
				bitCnt = 0
				cur = 0
				frameLen = MAX_FRAME
				symHalf = 0
				mPrev = 0
				firstBit = True
				state = ST_CAPTURE
			End If

		Case ST_CAPTURE
			wait = wait - 1
			If wait > 0 Then Return
			wait = SPS

			Dim c As Float = Back(3)
			Dim e As Float = Back(6)
			Dim l As Float = Back(0)

			'timing tracker (early/late), po simbolu
			Dim sw As Float = Abs(eyeS)
			If sw < 0.0001 Then sw = 0.0001
			Dim errE As Float = Abs(e - thrS)
			Dim errL As Float = Abs(l - thrS)
			tacc = tacc * T_LEAK + (errE - errL) / sw
			If tacc > T_LIMIT Then
				wait = SPS - 1 : tacc = 0
			Else If tacc < -T_LIMIT Then
				wait = SPS + 1 : tacc = 0
			End If

			If symHalf = 0 Then
				s1 = c
				symHalf = 1
			Else
				symHalf = 0
				Dim mv As Int = 0
				If c - s1 >= 0 Then mv = 1
				Dim bv As Int = 0
				If firstBit Then
					firstBit = False   'prvi bit okvira (MSB od 0x45) je uvijek 0
				Else If mv = mPrev Then
					bv = 1
				End If
				mPrev = mv

				cur = Bit.And(Bit.Or(Bit.ShiftLeft(cur, 1), bv), 0xFF)   'MSB first
				bitCnt = bitCnt + 1
				If bitCnt = 8 Then
					raw(nBytes) = cur
					nBytes = nBytes + 1
					cur = 0
					bitCnt = 0
					If nBytes = 1 Then
						Dim fl As Int = raw(0)
						If fl < 0x40 Or fl > 0x45 + 64 Then
							AbortFrame
							Return
						End If
						frameLen = fl + 1
					End If
					If nBytes >= frameLen Then FinishFrame
				End If
			End If
	End Select
End Sub

Private Sub AbortFrame
	FramesBad = FramesBad + 1
	state = ST_SEARCH
	ClearSr
End Sub

Private Sub FinishFrame
	Dim ok As Boolean = DecodeFrame(raw, frameLen)
	Eye = Abs(eyeS)
	state = ST_SEARCH
	ClearSr
	If SubExists(mCallback, mEvent & "_Frame") Then
		CallSubDelayed2(mCallback, mEvent & "_Frame", ok)
	End If
End Sub
