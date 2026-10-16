static struct BurnRomInfo mk2rev4RomDesc[] = {
	{ "mk2rev4.uj12",                              0x080000, 0xfd23dd93, 1 | BRF_PRG | BRF_ESS }, //  0 TMS34010
	{ "mk2rev4.ug12",                              0x080000, 0xd40d34fd, 1 | BRF_PRG | BRF_ESS }, //  1

	{ "mk2rev4.u2",                                0x080000, 0xfff86ce6, 2 | BRF_PRG | BRF_ESS }, //  2 DCS sound banks
	{ "mk2rev4.u3",                                0x080000, 0xa5d9baa8, 2 | BRF_PRG | BRF_ESS }, //  3
	{ "mk2rev4.u4",                                0x080000, 0x51ef6866, 2 | BRF_PRG | BRF_ESS }, //  4
	{ "mk2rev4.u5",                                0x080000, 0x373de0e7, 2 | BRF_PRG | BRF_ESS }, //  5
	{ "mk2rev4.u6",                                0x080000, 0xb05d11bf, 2 | BRF_PRG | BRF_ESS }, //  6
	{ "mk2rev4.u7",                                0x080000, 0xa51de7aa, 2 | BRF_PRG | BRF_ESS }, //  7

	{ "mk2rev4.ug14",                              0x100000, 0x9c864f0f, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x00, 0) }, //  8 GFX
	{ "mk2rev4.uj14",                              0x100000, 0x3314f622, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x00, 1) }, //  9
	{ "mk2rev4.ug19",                              0x100000, 0xe768a4ce, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x00, 2) }, //  10
	{ "mk2rev4.uj19",                              0x100000, 0x04305b16, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x00, 3) }, //  11
	{ "mk2rev4.ug16",                              0x100000, 0x1e5325f3, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x04, 0) }, //  12
	{ "mk2rev4.uj16",                              0x100000, 0x8004a3b6, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x04, 1) }, //  13
	{ "mk2rev4.ug20",                              0x100000, 0x0c929fba, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x04, 2) }, //  14
	{ "mk2rev4.uj20",                              0x100000, 0x7ed4ba0d, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x04, 3) }, //  15
	{ "mk2rev4.ug17",                              0x100000, 0x3924479e, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x08, 0) }, //  16
	{ "mk2rev4.uj17",                              0x100000, 0xa1af4391, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x08, 1) }, //  17
	{ "mk2rev4.ug22",                              0x100000, 0xd7bd61c3, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x08, 2) }, //  18
	{ "mk2rev4.uj22",                              0x100000, 0x53dc6b89, 3 | BRF_GRA | BRF_ESS | TUNIT_GFX(0x08, 3) }, //  19
};

STD_ROM_PICK(mk2rev4)
STD_ROM_FN(mk2rev4)

struct BurnDriver BurnDrvMk2rev4 = {
	"mk2rev4", "mk2", NULL, NULL, "2026",
	"Mortal Kombat II (rev 4.0)\0", NULL, "hack", "Midway T-Unit",
	NULL, NULL, NULL, NULL,
	BDF_GAME_WORKING | BDF_CLONE | BDF_HACK, 2, HARDWARE_MIDWAY_TUNIT, GBF_VSFIGHT, 0,
	NULL, mk2rev4RomInfo, mk2rev4RomName, NULL, NULL, NULL, NULL, Mk2InputInfo, Mk2DIPInfo,
    Mk2Init, TUnitExit, TUnitFrame, TUnitDraw, TUnitScan, &nTUnitRecalc, 0x8000,
    TUNIT_SCREEN_WIDTH, TUNIT_SCREEN_HEIGHT, 4, 3
};
