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
#include <power/regulator.h>
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
 *  - enable power (via regulator 'vcc3v3_pcie30' only)
 *  - delay 100 ms
 *  - deassert reset
 *  - delay 1000 ms (controller ready)
 *
 * Power MUST be managed by the regulator driver (`vcc3v3_pcie30`).
 * Board code will NOT attempt to control regulator-owned GPIOs.
 */
int rk_board_init(void)
{
	ofnode node;
	struct gpio_desc nvme_rst = {0};
	struct udevice *vreg = NULL;
	int ret;

	node = ofnode_path("/pcie3x4");
	if (!ofnode_valid(node))
		return 0;

	/* Request PCIe reset GPIO (use the controller's reset-gpios) */
	ret = gpio_request_by_name_nodev(node, "reset-gpios", 0,
		 &nvme_rst, GPIOD_IS_OUT);
	if (ret)
		debug("nvme: cannot request pcie reset-gpios (%d)\n", ret);

	/* Hold reset low to discharge */
	if (dm_gpio_is_valid(&nvme_rst))
		dm_gpio_set_value(&nvme_rst, 0);
	mdelay(300);

	/* Power on: obtain regulator from pcie node's 'vpcie3v3-supply' */
	{
		struct ofnode_phandle_args args;

		ret = ofnode_parse_phandle_with_args(node, "vpcie3v3-supply",
				 NULL, 0, 0, &args);
		if (!ret) {
			ret = uclass_get_device_by_ofnode(UCLASS_REGULATOR,
				 args.node, &vreg);
			if (!ret) {
				ret = regulator_set_enable(vreg, true);
				if (ret)
					debug("nvme: regulator enable failed (%d)\n", ret);
			} else {
				debug("nvme: vpcie3v3-supply present but regulator device not found\n");
			}
		} else {
			debug("nvme: pcie node has no vpcie3v3-supply property\n");
		}
	}

	/* allow power to settle before deasserting reset */
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
