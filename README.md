# perfect-tetris

## Upper bound for no. of distinct starting positions for empty board up till 6 pieces (2-line PC)

```text
7 * 31,920 // With hold
+ 154,980  // Empty hold
= 378,420  // Actual: 57,750
```

### Possible bags for next 5 pieces

5   = 2,520\
4 1 = 5,880\
3 2 = 8,820\
2 3 = 8,820\
1 4 = 5,880

### Possible bags for next 6 pieces

6   = 5,040\
5 1 = 17,640\
4 2 = 35,280\
3 3 = 44,100\
2 4 = 35,280\
1 5 = 17,640

## Upper bound for no. of distinct starting positions for empty board up till 11 pieces (4-line PC)

```text
7 * 19,897,920 // With hold
+ 57,576,960   // Empty hold
= 196,862,400  // Actual: 79,516,080
```

### Possible bags for next 10 pieces

7 3   = 1,058,400\
6 4   = 4,233,600\
5 5   = 6,350,400\
4 6   = 4,233,600\
3 7   = 1,058,400\
2 7 1 = 1,481,760\
1 7 2 = 1,481,760

### Possible bags for next 11 pieces

7 4   = 4,233,600\
6 5   = 12,700,800\
5 6   = 12,700,800\
4 7   = 4,233,600\
3 7 1 = 7,408,800\
2 7 2 = 8,890,560\
1 7 3 = 7,408,800

## Upper bound for no. of distinct starting positions for empty board up till 16 pieces (6-line PC)

```text
7 * 11,379,916,800 // With hold
+ 35,384,428,800   // Empty hold
= 115,043,846,400  // Actual: 57,596,696,640
```

### Possible bags for next 15 pieces

7 7 1 = 177,811,200\
6 7 2 = 1,066,867,200\
5 7 3 = 2,667,168,000\
4 7 4 = 3,556,224,000\
3 7 5 = 2,667,168,000\
2 7 6 = 1,066,867,200\
1 7 7 = 177,811,200

### Possible bags for next 16 pieces

7 7 2   = 1,066,867,200\
6 7 3   = 5,334,336,000\
5 7 4   = 10,668,672,000\
4 7 5   = 10,668,672,000\
3 7 6   = 5,334,336,000\
2 7 7   = 1,066,867,200\
1 7 7 1 = 1,244,678,400

## Some values for bag sequences (no hold)

 1:              7 | Distinct:              7 | 0ns
 2:             91 | Distinct:             49 | 0ns
 3:            798 | Distinct:            336 | 1.012ms
 4:          5,544 | Distinct:          2,184 | 986.9us
 5:         31,920 | Distinct:         13,020 | 4.027ms
 6:        154,980 | Distinct:         69,300 | 17.039ms
 7:        640,080 | Distinct:        322,560 | 53.001ms
 8:      2,257,920 | Distinct:      1,290,240 | 152.348ms
 9:      7,020,720 | Distinct:      4,495,680 | 414.167ms
10:     19,897,920 | Distinct:     14,248,080 | 1.185s
11:     57,576,960 | Distinct:     46,010,160 | 3.82s
12:    198,979,200 | Distinct:    172,559,520 | 15.073s
13:    806,500,800 | Distinct:    727,624,800 | 2m16.363s
14:  3,226,003,200 | Distinct:  2,965,974,480 | 1m4.03s
15: 11,379,916,800 | Distinct: 10,466,663,040 | 4m16.799s
16: 35,384,428,800 | Distinct: 33,452,027,280 | 18m30.784s

## values for next sequence (with hold)

 1:             28 | 0ns
 2:            196 | 0ns
 3:          1,365 | 0ns
 4:          9,198 | 0ns
 5:         57,750 | 1.03ms
 6:        326,340 | 3.006ms
 7:      1,615,320 | 19.363ms
 8:      6,849,360 | 31.392ms
 9:     24,857,280 | 89.685ms
10:     79,516,080 | 230.081ms
11:    247,474,080 | 647.921ms
12:    880,180,560 | 2.335s
13:  3,683,700,720 | 9.252s
14: 15,528,492,000 | 42.102s
15: 57,596,696,640 | 3m7.601s
