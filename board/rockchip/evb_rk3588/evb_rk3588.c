/*
 * SPDX-License-Identifier:     GPL-2.0+
 *
 * (C) Copyright 2021 Rockchip Electronics Co., Ltd
 */

#include <common.h>
#include <dwc3-uboot.h>
#include <usb.h>
#include <dm/ofnode.h>
#include <dm.h>
#include <sysreset.h>
#include <errno.h>
#include <asm/gpio.h>
#include <linux/delay.h>
#include <asm/io.h>

DECLARE_GLOBAL_DATA_PTR;

#ifdef CONFIG_USB_DWC3
static struct dwc3_device dwc3_device_data = {
	.maximum_speed = USB_SPEED_HIGH,
	.base = 0xfc000000,
	.dr_mode = USB_DR_MODE_PERIPHERAL,
	.index = 0,
	.dis_u2_susphy_quirk = 1,
	.usb2_phyif_utmi_width = 16,
};

int usb_gadget_handle_interrupts(void)
{
	dwc3_uboot_handle_interrupt(0);
	return 0;
}

int board_usb_init(int index, enum usb_init_type init)
{
	return dwc3_uboot_init(&dwc3_device_data);
}
#endif

/*
 * rk_board_init: implement NVMe physical reset sequence for M.2 slot
 * Sequence (required):
 *  - assert reset low 300 ms (discharge)
 *  - assert power
 *  - delay 100 ms
 *  - deassert reset
 *  - delay 1000 ms (controller ready)
 */
int rk_board_init(void)
{
	ofnode node;
	struct gpio_desc nvme_pwr = {0}, nvme_rst = {0};
	int ret;

	node = ofnode_path("/pcie3x4/nvme-reset");
	if (!ofnode_valid(node))
		return 0; /* no NVMe reset node — nothing to do */

	ret = gpio_request_by_name_nodev(node, "pwr-gpios", 0,
					 &nvme_pwr, GPIOD_IS_OUT);
	if (ret)
		debug("nvme: cannot request pwr-gpios (%d)\n", ret);

	ret = gpio_request_by_name_nodev(node, "rst-gpios", 0,
					 &nvme_rst, GPIOD_IS_OUT);
	if (ret)
		debug("nvme: cannot request rst-gpios (%d)\n", ret);

	/* Hold reset low to discharge */
	if (dm_gpio_is_valid(&nvme_rst))
		dm_gpio_set_value(&nvme_rst, 0);
	mdelay(300);

	/* Power on */
	if (dm_gpio_is_valid(&nvme_pwr))
		dm_gpio_set_value(&nvme_pwr, 1);
	mdelay(100);

	/* Release reset and wait for controller ready */
	if (dm_gpio_is_valid(&nvme_rst))
		dm_gpio_set_value(&nvme_rst, 1);
	mdelay(1000);

	return 0;
}

/* Use sysreset UCLASS to perform a cold reset via the sysreset driver */
void reset_cpu(ulong ignored)
{
	struct udevice *dev;
	int ret;

	/* Prefer the board driver instance if present */
	ret = uclass_get_device(UCLASS_SYSRESET, 0, &dev);
	if (!ret) {
		ret = sysreset_request(dev, SYSRESET_COLD);
		if (ret == -EINPROGRESS)
			hang(); /* reset in progress */
	}

	/* Fallback: walk all sysreset providers */
	ret = sysreset_walk(SYSRESET_COLD);
	if (ret == -EINPROGRESS)
		hang();

	/* If reset wasn't performed, hang to avoid returning */
	hang();
}
