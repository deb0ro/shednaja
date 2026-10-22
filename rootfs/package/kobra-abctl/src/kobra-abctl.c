/*
 * kobra-abctl - minimal replacement for Rockchip's rk_ota A/B "misc" handling.
 *
 * The A/B state lives in the misc partition at offset 2048 (Rockchip AvbABData,
 * 32 bytes): magic "\0AB0", version 1.0, 2 slots x {priority, tries_remaining,
 * successful_boot, reserved}, last_boot, reserved, crc32 (stored big endian, as
 * libavb's avb_htobe32) over the first 28 bytes. SPL boots the slot with the highest priority and
 * counts tries_remaining down; at 0 it falls back to the other slot.
 *
 * Behaviour copied from the stock rk_ota (measured under qemu on our misc dump,
 * see docs/rootfs-build.md):
 *   now   (= rk_ota --misc=now --mode=retry): the current slot is the one with the
 *         highest priority; set its tries_remaining=7, successful_boot=0 and
 *         last_boot to it. Stock runs this on every boot (S99_bootcontrol).
 *   other (= rk_ota --misc=other --mode=retry): other slot priority 15, tries 7,
 *         successful 0; the current slot only drops to priority 14 (its tries and
 *         successful flag stay) -> SPL boots the other slot next.
 *   display: print the state.
 * The file is only rewritten when something changes.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define MISC_DEV  "/dev/block/by-name/misc"
#define AB_OFFSET 2048
#define AB_SIZE   32
#define TRIES     7

static uint32_t crc32(const uint8_t *p, size_t n)
{
	uint32_t c = 0xffffffffu;
	while (n--) {
		c ^= *p++;
		for (int k = 0; k < 8; k++)
			c = (c >> 1) ^ (0xedb88320u & -(c & 1));
	}
	return ~c;
}

static uint32_t get_be32(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
}

static void put_be32(uint8_t *p, uint32_t v)
{
	p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static void show(const uint8_t *d)
{
	for (int i = 0; i < 2; i++)
		printf("slot %c: priority %u tries_remaining %u successful_boot %u\n",
		       'a' + i, d[8 + 4 * i], d[9 + 4 * i], d[10 + 4 * i]);
	printf("last_boot %u\n", d[16]);
}

int main(int argc, char **argv)
{
	const char *dev = MISC_DEV;
	uint8_t d[AB_SIZE], o[AB_SIZE];
	int fd, cur;

	if (argc < 2 || argc > 3) {
		fprintf(stderr, "usage: %s now|other|display [misc device/file]\n", argv[0]);
		return 2;
	}
	if (argc == 3)
		dev = argv[2];
	fd = open(dev, strcmp(argv[1], "display") ? O_RDWR : O_RDONLY);
	if (fd < 0 || pread(fd, d, AB_SIZE, AB_OFFSET) != AB_SIZE) {
		fprintf(stderr, "%s: %s\n", dev, strerror(errno));
		return 1;
	}
	if (memcmp(d, "\0AB0", 4) || d[4] != 1) {
		fprintf(stderr, "no AvbABData v1 at offset %d\n", AB_OFFSET);
		return 1;
	}
	if (get_be32(d + 28) != crc32(d, 28)) {
		fprintf(stderr, "AvbABData crc mismatch - not touching it\n");
		return 1;
	}
	memcpy(o, d, AB_SIZE);
	cur = d[12] > d[8] ? 1 : 0;	/* highest priority = slot SPL boots */

	if (!strcmp(argv[1], "display")) {
		show(d);
		printf("current (highest priority): %c\n", 'a' + cur);
		return 0;
	} else if (!strcmp(argv[1], "now")) {
		d[9 + 4 * cur] = TRIES;
		d[10 + 4 * cur] = 0;
		d[16] = cur;
	} else if (!strcmp(argv[1], "other")) {
		int oth = !cur;
		d[8 + 4 * oth] = 15; d[9 + 4 * oth] = TRIES; d[10 + 4 * oth] = 0;
		d[8 + 4 * cur] = 14;
	} else {
		fprintf(stderr, "unknown command %s\n", argv[1]);
		return 2;
	}
	put_be32(d + 28, crc32(d, 28));
	if (memcmp(d, o, AB_SIZE)) {
		if (pwrite(fd, d, AB_SIZE, AB_OFFSET) != AB_SIZE || fsync(fd)) {
			fprintf(stderr, "write %s: %s\n", dev, strerror(errno));
			return 1;
		}
		printf("updated:\n");
	}
	show(d);
	close(fd);
	return 0;
}
