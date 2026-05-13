#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/of.h>
#include <linux/delay.h>

#include <linux/iio/iio.h>
#include <linux/iio/sysfs.h>
#include <linux/iio/buffer.h>
#include <linux/iio/trigger.h>
#include <linux/iio/triggered_buffer.h>
#include <linux/iio/trigger_consumer.h>
#include <linux/interrupt.h>
#include <linux/irq.h>

#include "icm20948_regs.h"

#define ICM_RESET_TIME		100
#define SLAVE_XFER_TIME		5
#define MAG_RESET_TIME		1

#define I2C_SLV_ADDR_READ	(1 << 7)

#define MAG_I2C_ADDR		0x0c

// offset: +21 deg celsius
#define TEMP_OFFSET		21000

// scale: 333.87 LSB/deg celsius
#define TEMP_SCALE		(100 * 1000)
#define TEMP_SCALE_DIV		33387

// scale: 32752 LSB/4912 uT (-> 49.12 Gs)
#define MAG_SCALE		4912
#define MAG_SCALE_DIV		(100 * 32752)

typedef enum {
	ICM20948_SCAN_ACCL_X = 0,
	ICM20948_SCAN_ACCL_Y,
	ICM20948_SCAN_ACCL_Z,
	ICM20948_SCAN_GYRO_X,
	ICM20948_SCAN_GYRO_Y,
	ICM20948_SCAN_GYRO_Z,
	ICM20948_SCAN_TEMP,
	ICM20948_SCAN_MAG_X,
	ICM20948_SCAN_MAG_Y,
	ICM20948_SCAN_MAG_Z,
	ICM20948_SCAN_TIMESTAMP,
} ICM20948_SCAN_T;

typedef struct {
	struct i2c_client *client;
	struct iio_mount_matrix orientation;
	struct iio_trigger *trig;	/* data-ready IRQ trigger; NULL if no IRQ wired */
	struct mutex lock;
	uint8_t bank_reg;
	uint8_t mag_overrange;	/* sticky AK09916 HOFL; cleared by writing 0 to in_magn_overrange */
} ICM20948_DATA_T;

typedef struct {
	int16_t x;
	int16_t y;
	int16_t z;
} __attribute__((__packed__)) ICM20948_3D_VECT_T;

typedef struct {
	ICM20948_3D_VECT_T h;
	uint8_t st2;
	uint8_t dummy;
} __attribute__((__packed__)) ICM20948_MAG_DATA_T;

typedef struct {
	ICM20948_3D_VECT_T accel;
	ICM20948_3D_VECT_T gyro;
	int16_t temp;
	ICM20948_3D_VECT_T mag;
} __attribute__((__packed__)) ICM20948_SENS_DATA_T;

typedef struct {
	ICM20948_SENS_DATA_T sens;
	uint8_t pad[sizeof(ICM20948_SENS_DATA_T) % sizeof(int64_t)];
	int64_t timestamp;
} __attribute__((__packed__)) ICM20948_BUFFER_DATA_T;

/*
 * What the slave-0 burst writes into BANK_0 EXT_SLV_SENS_DATA_*. The first
 * 20 bytes match ICM20948_SENS_DATA_T and feed straight into the IIO scan
 * buffer. The trailing 2 bytes capture the AK09916's ST2 (overflow flag in
 * bit 3) and the unused TMPS dummy byte — read but not pushed into the
 * IIO buffer.
 */
typedef struct {
	ICM20948_SENS_DATA_T sens;
	uint8_t mag_st2;
	uint8_t mag_tmps;
} __attribute__((__packed__)) ICM20948_BURST_DATA_T;

typedef struct {
	int vals[2];
	int reg_val;
} ICM20948_LOOKUP_ITEM_T;

typedef struct {
	int type;
	long chan_mask;
	enum iio_chan_type chan_type;
	int reg;
	int reg_mask;
	ICM20948_LOOKUP_ITEM_T items[];
} ICM20948_LOOKUP_HEAD_T;

static const ICM20948_LOOKUP_HEAD_T icm20948_accel_filter_lookup = {
	.type = IIO_VAL_INT_PLUS_MICRO,
	.chan_mask = IIO_CHAN_INFO_LOW_PASS_FILTER_3DB_FREQUENCY,
	.chan_type = IIO_ACCEL,
	.reg = ACCEL_CONFIG,
	.reg_mask = RV_ACCEL_FCHOICE | RV_ACCEL_DLPFCFG_0 | RV_ACCEL_DLPFCFG_1 | RV_ACCEL_DLPFCFG_2,
	.items = {
		{ { 1209,      0 }, 0 },
		{ {  246,      0 }, RV_ACCEL_FCHOICE | RV_ACCEL_DLPFCFG(0) },
		{ {  111, 400000 }, RV_ACCEL_FCHOICE | RV_ACCEL_DLPFCFG(2) },
		{ {   50, 400000 }, RV_ACCEL_FCHOICE | RV_ACCEL_DLPFCFG(3) },
		{ {   23, 900000 }, RV_ACCEL_FCHOICE | RV_ACCEL_DLPFCFG(4) },
		{ {   11, 500000 }, RV_ACCEL_FCHOICE | RV_ACCEL_DLPFCFG(5) },
		{ {    5, 700000 }, RV_ACCEL_FCHOICE | RV_ACCEL_DLPFCFG(6) },
		{ {  473,      0 }, RV_ACCEL_FCHOICE | RV_ACCEL_DLPFCFG(7) },
		{ { 0, 0 }, -1}
	}
};

static const ICM20948_LOOKUP_HEAD_T icm20948_anglvel_filter_lookup = {
	.type = IIO_VAL_INT_PLUS_MICRO,
	.chan_mask = IIO_CHAN_INFO_LOW_PASS_FILTER_3DB_FREQUENCY,
	.chan_type = IIO_ANGL_VEL,
	.reg = GYRO_CONFIG_1,
	.reg_mask = RV_GYRO_FCHOICE | RV_GYRO_DLPFCFG_0 | RV_GYRO_DLPFCFG_1 | RV_GYRO_DLPFCFG_2,
	.items = {
		{ { 12106,      0 }, 0 },
		{ {   196, 600000 }, RV_GYRO_FCHOICE | RV_GYRO_DLPFCFG(0) },
		{ {   151, 800000 }, RV_GYRO_FCHOICE | RV_GYRO_DLPFCFG(1) },
		{ {   119, 500000 }, RV_GYRO_FCHOICE | RV_GYRO_DLPFCFG(2) },
		{ {    51, 200000 }, RV_GYRO_FCHOICE | RV_GYRO_DLPFCFG(3) },
		{ {    23, 900000 }, RV_GYRO_FCHOICE | RV_GYRO_DLPFCFG(4) },
		{ {    11, 600000 }, RV_GYRO_FCHOICE | RV_GYRO_DLPFCFG(5) },
		{ {     5, 700000 }, RV_GYRO_FCHOICE | RV_GYRO_DLPFCFG(6) },
		{ {   361, 400000 }, RV_GYRO_FCHOICE | RV_GYRO_DLPFCFG(7) },
		{ { 0, 0 }, -1}
	}
};

static const ICM20948_LOOKUP_HEAD_T icm20948_temp_filter_lookup = {
	.type = IIO_VAL_INT_PLUS_MICRO,
	.chan_mask = IIO_CHAN_INFO_LOW_PASS_FILTER_3DB_FREQUENCY,
	.chan_type = IIO_TEMP,
	.reg = TEMP_CONFIG,
	.reg_mask = RV_TEMP_DLPFCFG_0 | RV_TEMP_DLPFCFG_1 | RV_TEMP_DLPFCFG_2,
	.items = {
		{ { 7932,      0 }, RV_TEMP_DLPFCFG(0) },
		{ {  217, 900000 }, RV_TEMP_DLPFCFG(1) },
		{ {  123, 500000 }, RV_TEMP_DLPFCFG(2) },
		{ {   65, 900000 }, RV_TEMP_DLPFCFG(3) },
		{ {   34, 100000 }, RV_TEMP_DLPFCFG(4) },
		{ {   17, 300000 }, RV_TEMP_DLPFCFG(5) },
		{ {    8, 800000 }, RV_TEMP_DLPFCFG(6) },
		{ { 0, 0 }, -1}
	}
};

static const ICM20948_LOOKUP_HEAD_T icm20948_accel_scale_lookup = {
	.type = IIO_VAL_INT_PLUS_NANO,
	.chan_mask = IIO_CHAN_INFO_SCALE,
	.chan_type = IIO_ACCEL,
	.reg = ACCEL_CONFIG,
	.reg_mask = RV_ACCEL_FS_SEL_0 | RV_ACCEL_FS_SEL_1,
	.items = {
		{ { 0,  598550 }, RV_ACCEL_FS_SEL(0) }, // 9.80665 m/s2 / 16384 LSB/g
		{ { 0, 1197100 }, RV_ACCEL_FS_SEL(1) }, // 9.80665 m/s2 /  8192 LSB/g
		{ { 0, 2394201 }, RV_ACCEL_FS_SEL(2) }, // 9.80665 m/s2 /  4096 LSB/g
		{ { 0, 4788403 }, RV_ACCEL_FS_SEL(3) }, // 9.80665 m/s2 /  2048 LSB/g
		{ { 0, 0 }, -1}
	}
};

static const ICM20948_LOOKUP_HEAD_T icm20948_anglvel_scale_lookup = {
	.type = IIO_VAL_INT_PLUS_NANO,
	.chan_mask = IIO_CHAN_INFO_SCALE,
	.chan_type = IIO_ANGL_VEL,
	.reg = GYRO_CONFIG_1,
	.reg_mask = RV_GYRO_FS_SEL_0 | RV_GYRO_FS_SEL_1,
	.items = {
		{ { 0,  133158 }, RV_GYRO_FS_SEL(0) }, //  250 dps/fs * (pi/180) / 32768 LSB/fs
		{ { 0,  266316 }, RV_GYRO_FS_SEL(1) }, //  500 dps/fs * (pi/180) / 32768 LSB/fs
		{ { 0,  532632 }, RV_GYRO_FS_SEL(2) }, // 1000 dps/fs * (pi/180) / 32768 LSB/fs
		{ { 0, 1065264 }, RV_GYRO_FS_SEL(3) }, // 2000 dps/fs * (pi/180) / 32768 LSB/fs
		{ { 0, 0 }, -1}
	}
};

typedef enum {
	ICM20948_LOOKUP_ACCEL_FILTER = 0,
	ICM20948_LOOKUP_ANGLVAL_FILTER,
	ICM20948_LOOKUP_TEMP_FILTER,
	ICM20948_LOOKUP_ACCEL_SCALE,
	ICM20948_LOOKUP_ANGLVAL_SCALE,
	ICM20948_LOOKUP_COUNT
} ICM20948_LOOKUPS_T;

const ICM20948_LOOKUP_HEAD_T * const icm20948_lookup_tab[ICM20948_LOOKUP_COUNT] = {
	&icm20948_accel_filter_lookup,
	&icm20948_anglvel_filter_lookup,
	&icm20948_temp_filter_lookup,
	&icm20948_accel_scale_lookup,
	&icm20948_anglvel_scale_lookup
};


static int icm20948_select_bank(ICM20948_DATA_T *icm, uint8_t bank) {
	int ret;

	if (icm->bank_reg == bank) {
		return 0;
	}

	ret = i2c_smbus_write_byte_data(icm->client, REG_BANK_SEL, bank);
	if (ret < 0) {
		return ret;
	}

	icm->bank_reg = bank;

	return 0;
}

static int icm20948_read(ICM20948_DATA_T *icm, ICM20948_BURST_DATA_T *data) {
	int ret;

	ret = icm20948_select_bank(icm, ACCEL_XOUT_H >> 8);
	if (ret < 0) {
		return ret;
	}

	return i2c_smbus_read_i2c_block_data(icm->client, ACCEL_XOUT_H & 0xff, sizeof(ICM20948_BURST_DATA_T), (unsigned char *) data);
}

static int icm20948_read_byte(ICM20948_DATA_T *icm, uint16_t reg) {
	int ret;

	ret = icm20948_select_bank(icm, reg >> 8);
	if (ret < 0) {
		return ret;
	}

	return i2c_smbus_read_byte_data(icm->client, reg & 0xff);
}

static int icm20948_write_byte(ICM20948_DATA_T *icm, uint16_t reg, uint8_t val) {
	int ret;

	ret = icm20948_select_bank(icm, reg >> 8);
	if (ret < 0) {
		return ret;
	}

	return i2c_smbus_write_byte_data(icm->client, reg & 0xff, val);
}

static int icm20948_read_word(ICM20948_DATA_T *icm, uint16_t reg) {
	int ret;

	ret = icm20948_select_bank(icm, reg >> 8);
	if (ret < 0) {
		return ret;
	}

	ret = i2c_smbus_read_word_data(icm->client, reg & 0xff);
	if (ret < 0) {
		return ret;
	}
	return be16_to_cpu((uint16_t) ret);
}

static int icm20948_write_word(ICM20948_DATA_T *icm, uint16_t reg, uint16_t val) {
	int ret;

	ret = icm20948_select_bank(icm, reg >> 8);
	if (ret < 0) {
		return ret;
	}

	return i2c_smbus_write_word_data(icm->client, reg & 0xff, cpu_to_be16(val));
}

static int icm20948_slave_xfer_byte(ICM20948_DATA_T *icm, uint8_t addr, uint8_t reg, uint8_t val) {
	int rval = 0;
	int ret;

	// check for idle slave
	ret = icm20948_read_byte(icm, I2C_SLV4_CTRL);
	if (ret < 0) {
		return ret;
	}
	if ((ret & RV_I2C_SLV4_EN) != 0) {
		dev_err(&icm->client->dev, "i2c slave: transaction not idle.\n");
		return -EIO;
	}

	// set slave address
	ret = icm20948_write_byte(icm, I2C_SLV4_ADDR, addr);
	if (ret < 0) {
		return ret;
	}

	// set slave register
	ret = icm20948_write_byte(icm, I2C_SLV4_REG, reg);
	if (ret < 0) {
		return ret;
	}

	// set output data on write
	if ((addr & I2C_SLV_ADDR_READ) == 0) {
		ret = icm20948_write_byte(icm, I2C_SLV4_DO, val);
		if (ret < 0) {
			return ret;
		}
	}

	// start the transaction
	ret = icm20948_write_byte(icm, I2C_SLV4_CTRL, RV_I2C_SLV4_EN);
	if (ret < 0) {
		return ret;
	}

	// wait 5 ms for transfer
	msleep(SLAVE_XFER_TIME);

	// get input data on read
	if ((addr & I2C_SLV_ADDR_READ) != 0) {
		rval = icm20948_read_byte(icm, I2C_SLV4_DI);
		if (rval < 0) {
			return rval;
		}
	}

	// check status
	ret = icm20948_read_byte(icm, I2C_MST_STATUS);
	if (ret < 0) {
		return ret;
	}
	if ((ret & RV_I2C_SLV4_NACK) != 0) {
		dev_err(&icm->client->dev, "i2c slave %02x: slave not responding.\n", addr & 0x7f);
		return -ENODEV;
	}
	if ((ret & RV_I2C_SLV4_DONE) == 0) {
		dev_err(&icm->client->dev, "i2c slave %02x: transaction not done.\n", addr & 0x7f);
		return -ETIMEDOUT;
	}

	return rval;
}

static int icm20948_slave_read_byte(ICM20948_DATA_T *icm, uint8_t addr, uint8_t reg) {
	int ret;

	// read -> bit7 = 1
	mutex_lock(&icm->lock);
	ret = icm20948_slave_xfer_byte(icm, addr | I2C_SLV_ADDR_READ, reg, 0);
	mutex_unlock(&icm->lock);

	return ret;
}

static int icm20948_slave_write_byte(ICM20948_DATA_T *icm, uint8_t addr, uint8_t reg, uint8_t val) {
	int ret;

	// write -> bit7 = 0
	mutex_lock(&icm->lock);
	ret = icm20948_slave_xfer_byte(icm, addr & ~I2C_SLV_ADDR_READ, reg, val);
	mutex_unlock(&icm->lock);

	return ret;
}

static ssize_t icm20948_show_available(struct device *dev,
			struct device_attribute *attr,
			char *buf)
{
	struct iio_dev_attr *this_attr = to_iio_dev_attr(attr);
	const ICM20948_LOOKUP_HEAD_T *lookup = icm20948_lookup_tab[this_attr->address];
	const ICM20948_LOOKUP_ITEM_T *item;
	ssize_t len = 0;

	for (item = lookup->items; item->reg_val >= 0; item++) {
		if (len > 0) {
			buf[len - 1] = ' ';
		}

		len +=  iio_format_value(&buf[len], lookup->type, 0, (int *) item->vals);
	}

	return len;
}

/*
 * AK09916 ST2.HOFL is set whenever a measurement saturated the chip's
 * ±4912 µT range. The buffered trigger handler latches it into
 * icm->mag_overrange. The attribute is sticky; userspace clears it by
 * writing "0" (the only accepted write value). Single-shot sysfs reads
 * of in_magn_*_raw do NOT update this flag — only the buffered path.
 */
static ssize_t icm20948_show_mag_overrange(struct device *dev,
			struct device_attribute *attr, char *buf)
{
	struct iio_dev *indio_dev = dev_to_iio_dev(dev);
	ICM20948_DATA_T *icm = (ICM20948_DATA_T *) iio_priv(indio_dev);
	return sprintf(buf, "%u\n", READ_ONCE(icm->mag_overrange));
}

static ssize_t icm20948_store_mag_overrange(struct device *dev,
			struct device_attribute *attr,
			const char *buf, size_t count)
{
	struct iio_dev *indio_dev = dev_to_iio_dev(dev);
	ICM20948_DATA_T *icm = (ICM20948_DATA_T *) iio_priv(indio_dev);
	unsigned int val;
	int ret = kstrtouint(buf, 0, &val);
	if (ret) {
		return ret;
	}
	if (val != 0) {
		return -EINVAL;
	}
	WRITE_ONCE(icm->mag_overrange, 0);
	return count;
}

static int icm20948_read_lookup(ICM20948_DATA_T *icm,
	const ICM20948_LOOKUP_HEAD_T *lookup,
	int *val, int *val2)
{
	const ICM20948_LOOKUP_ITEM_T *item;
	int reg_val;

	mutex_lock(&icm->lock);
	reg_val = icm20948_read_byte(icm, lookup->reg);
	mutex_unlock(&icm->lock);
	if (reg_val < 0) {
		return reg_val;
	}

	reg_val &= lookup->reg_mask;

	for (item = lookup->items; item->reg_val >= 0; item++) {
		if (item->reg_val == reg_val) {
			*val = item->vals[0];
			*val2 = item->vals[1];
			return lookup->type;
		}
	}

	return -EINVAL;
}

static int icm20948_write_lookup(ICM20948_DATA_T *icm,
	const ICM20948_LOOKUP_HEAD_T *lookup,
	int val, int val2)
{
	const ICM20948_LOOKUP_ITEM_T *item;
	int reg_val, ret;

	for (item = lookup->items; item->reg_val >= 0; item++) {
		if (item->vals[0] == val && item->vals[1] == val2) {
			mutex_lock(&icm->lock);

			reg_val = icm20948_read_byte(icm, lookup->reg);
			if (reg_val < 0) {
				mutex_unlock(&icm->lock);
				return reg_val;
			}

			ret = icm20948_write_byte(icm, lookup->reg,
				(reg_val & ~lookup->reg_mask) | item->reg_val);

			mutex_unlock(&icm->lock);
			return ret;
		}
	}

	return -EINVAL;
}

/*
 * Data-ready trigger: enable/disable the chip's RAW_DATA_0_RDY interrupt.
 * Called by the IIO core when userspace selects this trigger as the buffer's
 * driving trigger (enable=true) or deselects it (enable=false).
 */
static int icm20948_data_rdy_trigger_set_state(struct iio_trigger *trig,
					       bool enable)
{
	struct iio_dev *indio_dev = iio_trigger_get_drvdata(trig);
	ICM20948_DATA_T *icm = (ICM20948_DATA_T *) iio_priv(indio_dev);
	int ret;

	mutex_lock(&icm->lock);
	ret = icm20948_write_byte(icm, INT_ENABLE_1,
		enable ? RV_RAW_DATA_0_RDY_EN : 0);
	mutex_unlock(&icm->lock);
	return ret;
}

static const struct iio_trigger_ops icm20948_trigger_ops = {
	.set_trigger_state = icm20948_data_rdy_trigger_set_state,
};

/*
 * Register a data-ready IRQ trigger if the i2c_client has an IRQ wired
 * via DT (interrupts = <...>). No-op otherwise — the driver still works,
 * just requires an external trigger (e.g. iio-trig-hrtimer) for buffered
 * capture.
 */
static int icm20948_setup_data_rdy_trigger(struct iio_dev *indio_dev)
{
	ICM20948_DATA_T *icm = (ICM20948_DATA_T *) iio_priv(indio_dev);
	struct i2c_client *client = icm->client;
	unsigned long irq_flags;
	int ret;

	if (client->irq <= 0) {
		return 0;
	}

	/*
	 * INT1 active-high, push-pull, latched, with any-register-read
	 * clearing the latch. The triggered_buffer handler does an I2C bulk
	 * read on every sample, which deasserts INT1 well before the next
	 * data-ready event.
	 */
	ret = icm20948_write_byte(icm, INT_PIN_CFG,
		RV_INT1_LATCH_EN | RV_INT_ANYRD_2CLEAR);
	if (ret < 0) {
		return ret;
	}

	/* INT_ENABLE_1 is left cleared; set_trigger_state turns it on. */
	ret = icm20948_write_byte(icm, INT_ENABLE_1, 0);
	if (ret < 0) {
		return ret;
	}

	icm->trig = devm_iio_trigger_alloc(&client->dev, "%s-dev%d",
		indio_dev->name, iio_device_id(indio_dev));
	if (!icm->trig) {
		return -ENOMEM;
	}
	icm->trig->ops = &icm20948_trigger_ops;
	iio_trigger_set_drvdata(icm->trig, indio_dev);

	ret = devm_iio_trigger_register(&client->dev, icm->trig);
	if (ret < 0) {
		return ret;
	}

	/* Auto-attach so userspace gets a working trigger out of the box. */
	indio_dev->trig = iio_trigger_get(icm->trig);

	/* Honour DT-specified IRQ trigger type if any; fall back to rising. */
	irq_flags = irqd_get_trigger_type(irq_get_irq_data(client->irq));
	if (!irq_flags) {
		irq_flags = IRQF_TRIGGER_RISING;
	}

	ret = devm_request_irq(&client->dev, client->irq,
		iio_trigger_generic_data_rdy_poll, irq_flags,
		"icm20948", icm->trig);
	if (ret < 0) {
		return ret;
	}

	dev_info(&client->dev,
		"data-ready trigger %s on IRQ %d\n",
		icm->trig->name, client->irq);
	return 0;
}

static irqreturn_t icm20948_trigger_handler(int irq, void *p)
{
	struct iio_poll_func *pf = p;
	struct iio_dev *indio_dev = pf->indio_dev;
	ICM20948_DATA_T *icm = (ICM20948_DATA_T *) iio_priv(indio_dev);
	int ret;
	ICM20948_BURST_DATA_T burst;
	ICM20948_BUFFER_DATA_T buffer;

	// read from sensor (22 bytes: 20 of sensor data + mag ST2 + mag dummy)
	mutex_lock(&icm->lock);
	ret = icm20948_read(icm, &burst);
	mutex_unlock(&icm->lock);
	if (ret < 0) {
		goto fail0;
	}

	buffer.sens = burst.sens;

	// mag y and z axis is flipped around the x axis
	buffer.sens.mag.y = -buffer.sens.mag.y;
	buffer.sens.mag.z = -buffer.sens.mag.z;

	// Latch the AK09916 overflow bit so userspace can detect a sample
	// where any axis saturated the ±4912 µT measurement range. Sticky
	// until cleared via `echo 0 > in_magn_overrange`.
	if (burst.mag_st2 & RV_MAG_HOFL) {
		WRITE_ONCE(icm->mag_overrange, 1);
	}

	buffer.timestamp = iio_get_time_ns(indio_dev);
	iio_push_to_buffers(indio_dev, &buffer);

fail0:
	iio_trigger_notify_done(indio_dev->trig);

	return IRQ_HANDLED;
}

static int icm20948_read_raw_word(ICM20948_DATA_T *icm, int reg, int chan, int *val) {
	int ret;

	if (chan >= 0) {
		reg += (chan - IIO_MOD_X) << 1;
	}

	mutex_lock(&icm->lock);
	ret = icm20948_read_word(icm, reg);
	mutex_unlock(&icm->lock);
	if (ret < 0) {
		return ret;
	}

	*val = (int16_t) ret;
	return IIO_VAL_INT;
}

static int icm20948_write_raw_word(ICM20948_DATA_T *icm, int reg, int chan, int val) {
	int ret;
	if (chan >= 0) {
		reg += (chan - IIO_MOD_X) << 1;
	}

	mutex_lock(&icm->lock);
	ret = icm20948_write_word(icm, reg, val);
	mutex_unlock(&icm->lock);

	return ret;
}

static int icm20948_read_raw(struct iio_dev *indio_dev,
				struct iio_chan_spec const *chan,
				int *val, int *val2, long mask)
{
	ICM20948_DATA_T *icm = (ICM20948_DATA_T *) iio_priv(indio_dev);
	const ICM20948_LOOKUP_HEAD_T *lookup;
	int i;

	for (i = 0; i < ICM20948_LOOKUP_COUNT; i++) {
		lookup = icm20948_lookup_tab[i];
		if (lookup->chan_mask == mask && lookup->chan_type == chan->type) {
			return icm20948_read_lookup(icm, lookup, val, val2);
		}
	}

	switch (mask) {
	case IIO_CHAN_INFO_RAW:
		switch (chan->type) {
		case IIO_ACCEL:
			if (chan->channel2 >= IIO_MOD_X && chan->channel2 <= IIO_MOD_Z) {
				return icm20948_read_raw_word(icm, ACCEL_XOUT_H, chan->channel2, val);
			}
			break;
		case IIO_ANGL_VEL:
			if (chan->channel2 >= IIO_MOD_X && chan->channel2 <= IIO_MOD_Z) {
				return icm20948_read_raw_word(icm, GYRO_XOUT_H, chan->channel2, val);
			}
			break;
		case IIO_MAGN:
			if (chan->channel2 >= IIO_MOD_X && chan->channel2 <= IIO_MOD_Z) {
				i = icm20948_read_raw_word(icm, EXT_SLV_SENS_DATA_00, chan->channel2, val);
				// mag y and z axis is flipped around the x axis
				if (i >= 0 && (chan->channel2 == IIO_MOD_Y || chan->channel2 == IIO_MOD_Z)) {
					*val = -*val;
				}
				return i;
			}
			break;
		case IIO_TEMP:
			return icm20948_read_raw_word(icm, TEMP_OUT_H, -1, val);
		default:
			break;
		}
		break;

	case IIO_CHAN_INFO_CALIBBIAS:
		switch (chan->type) {
		case IIO_ACCEL:
			if (chan->channel2 >= IIO_MOD_X && chan->channel2 <= IIO_MOD_Z) {
				return icm20948_read_raw_word(icm, XA_OFFS_H, chan->channel2, val);
			}
			break;
		case IIO_ANGL_VEL:
			if (chan->channel2 >= IIO_MOD_X && chan->channel2 <= IIO_MOD_Z) {
				return icm20948_read_raw_word(icm, XG_OFFS_USRH, chan->channel2, val);
			}
			break;
		default:
			break;
		}
		break;

	case IIO_CHAN_INFO_SCALE:
		switch (chan->type) {
		case IIO_MAGN:
			*val = MAG_SCALE;
			*val2 = MAG_SCALE_DIV;
			return IIO_VAL_FRACTIONAL;
		case IIO_TEMP:
			*val = TEMP_SCALE;
			*val2 = TEMP_SCALE_DIV;
			return IIO_VAL_FRACTIONAL;
		default:
			break;
		}
		break;

	case IIO_CHAN_INFO_OFFSET:
		switch (chan->type) {
		case IIO_TEMP:
			*val = TEMP_OFFSET;
			return IIO_VAL_INT;
		default:
			break;
		}
		break;
	}

	return -EINVAL;
}

static int icm20948_write_raw_int(struct iio_dev *indio_dev,
				struct iio_chan_spec const *chan,
				int val, int val2, long mask)
{
	ICM20948_DATA_T *icm = (ICM20948_DATA_T *) iio_priv(indio_dev);
	const ICM20948_LOOKUP_HEAD_T *lookup;
	int i;

	for (i = 0; i < ICM20948_LOOKUP_COUNT; i++) {
		lookup = icm20948_lookup_tab[i];
		if (lookup->chan_mask == mask && lookup->chan_type == chan->type) {
			return icm20948_write_lookup(icm, lookup, val, val2);
		}
	}

	switch (mask) {
	case IIO_CHAN_INFO_CALIBBIAS:
		switch (chan->type) {
		case IIO_ACCEL:
			if (chan->channel2 >= IIO_MOD_X && chan->channel2 <= IIO_MOD_Z) {
				return icm20948_write_raw_word(icm, XA_OFFS_H, chan->channel2, val);
			}
			break;
		case IIO_ANGL_VEL:
			if (chan->channel2 >= IIO_MOD_X && chan->channel2 <= IIO_MOD_Z) {
				return icm20948_write_raw_word(icm, XG_OFFS_USRH, chan->channel2, val);
			}
			break;
		default:
			break;
		}
		break;
	}

	return -EINVAL;
}

static int icm20948_write_raw(struct iio_dev *indio_dev,
				struct iio_chan_spec const *chan,
				int val, int val2, long mask)
{
	int ret;

	// allow writes on idle state only
	if (!iio_device_claim_direct(indio_dev)) {
		return -EBUSY;
	}

	ret = icm20948_write_raw_int(indio_dev, chan, val, val2, mask);
	iio_device_release_direct(indio_dev);
	return ret;
}

static int icm20948_write_raw_get_fmt(struct iio_dev *indio_dev,
				struct iio_chan_spec const *chan,
				long mask)
{
	const ICM20948_LOOKUP_HEAD_T *lookup;
	int i;

	for (i = 0; i < ICM20948_LOOKUP_COUNT; i++) {
		lookup = icm20948_lookup_tab[i];
		if (lookup->chan_mask == mask && lookup->chan_type == chan->type) {
			return lookup->type;
		}
	}

	return -EINVAL;
}

static IIO_DEVICE_ATTR(in_accel_filter_low_pass_3db_frequency_available,
	S_IRUGO, icm20948_show_available, NULL, ICM20948_LOOKUP_ACCEL_FILTER);
static IIO_DEVICE_ATTR(in_anglvel_filter_low_pass_3db_frequency_available,
	S_IRUGO, icm20948_show_available, NULL, ICM20948_LOOKUP_ANGLVAL_FILTER);
static IIO_DEVICE_ATTR(in_temp_filter_low_pass_3db_frequency_available,
	S_IRUGO, icm20948_show_available, NULL, ICM20948_LOOKUP_TEMP_FILTER);
static IIO_DEVICE_ATTR(in_accel_scale_available,
	S_IRUGO, icm20948_show_available, NULL, ICM20948_LOOKUP_ACCEL_SCALE);
static IIO_DEVICE_ATTR(in_anglvel_scale_available,
	S_IRUGO, icm20948_show_available, NULL, ICM20948_LOOKUP_ANGLVAL_SCALE);

static IIO_DEVICE_ATTR(in_magn_overrange,
	S_IRUGO | S_IWUSR,
	icm20948_show_mag_overrange, icm20948_store_mag_overrange, 0);

static struct attribute *icm20948_attrs[] = {
	&iio_dev_attr_in_accel_filter_low_pass_3db_frequency_available.dev_attr.attr,
	&iio_dev_attr_in_anglvel_filter_low_pass_3db_frequency_available.dev_attr.attr,
	&iio_dev_attr_in_temp_filter_low_pass_3db_frequency_available.dev_attr.attr,
	&iio_dev_attr_in_accel_scale_available.dev_attr.attr,
	&iio_dev_attr_in_anglvel_scale_available.dev_attr.attr,
	&iio_dev_attr_in_magn_overrange.dev_attr.attr,
	NULL
};

static const struct attribute_group icm20948_attrs_group = {
	.attrs = icm20948_attrs,
};

static const struct iio_info icm20948_info = {
	.read_raw = icm20948_read_raw,
	.write_raw = icm20948_write_raw,
	.write_raw_get_fmt = &icm20948_write_raw_get_fmt,
	.attrs = &icm20948_attrs_group
};

static const struct iio_mount_matrix *
icm20948_get_mount_matrix(const struct iio_dev *indio_dev,
			const struct iio_chan_spec *chan)
{
	ICM20948_DATA_T *icm = (ICM20948_DATA_T *) iio_priv(indio_dev);
	return &icm->orientation;
}

static const struct iio_chan_spec_ext_info icm20948_ext_info[] = {
	IIO_MOUNT_MATRIX(IIO_SHARED_BY_DIR, icm20948_get_mount_matrix),
	{ },
};

static const unsigned long icm20948_scan_masks[] =
	{ ((1 << ICM20948_SCAN_TIMESTAMP) - 1), 0};

#define ICM20948_CHAN_TYPE							\
	{									\
		.sign = 's',							\
		.realbits = 16,							\
		.storagebits = 16,						\
		.shift = 0,							\
		.endianness = IIO_BE,						\
	}

#define ICM20948_CHAN(_type, _channel2, _index)					\
	{									\
		.type = _type,							\
		.modified = 1,							\
		.channel2 = _channel2,						\
		.info_mask_shared_by_type = BIT(IIO_CHAN_INFO_SCALE) |		\
			BIT(IIO_CHAN_INFO_LOW_PASS_FILTER_3DB_FREQUENCY),	\
		.info_mask_separate = BIT(IIO_CHAN_INFO_RAW) |			\
			BIT(IIO_CHAN_INFO_CALIBBIAS),				\
		.scan_index = _index,						\
		.scan_type = ICM20948_CHAN_TYPE,				\
		.ext_info = icm20948_ext_info,					\
	}

#define ICM20948_MAG_CHAN(_type, _channel2, _index)				\
	{									\
		.type = _type,							\
		.modified = 1,							\
		.channel2 = _channel2,						\
		.info_mask_shared_by_type = BIT(IIO_CHAN_INFO_SCALE),		\
		.info_mask_separate = BIT(IIO_CHAN_INFO_RAW),			\
		.scan_index = _index,						\
		.scan_type = ICM20948_CHAN_TYPE,				\
		.ext_info = icm20948_ext_info,					\
	}

static const struct iio_chan_spec icm20948_channels[] = {
	ICM20948_CHAN(IIO_ACCEL, IIO_MOD_X, ICM20948_SCAN_ACCL_X),
	ICM20948_CHAN(IIO_ACCEL, IIO_MOD_Y, ICM20948_SCAN_ACCL_Y),
	ICM20948_CHAN(IIO_ACCEL, IIO_MOD_Z, ICM20948_SCAN_ACCL_Z),

	ICM20948_CHAN(IIO_ANGL_VEL, IIO_MOD_X, ICM20948_SCAN_GYRO_X),
	ICM20948_CHAN(IIO_ANGL_VEL, IIO_MOD_Y, ICM20948_SCAN_GYRO_Y),
	ICM20948_CHAN(IIO_ANGL_VEL, IIO_MOD_Z, ICM20948_SCAN_GYRO_Z),

	{
		.type = IIO_TEMP,
		.info_mask_shared_by_type = BIT(IIO_CHAN_INFO_SCALE) |
			BIT(IIO_CHAN_INFO_OFFSET) |
			BIT(IIO_CHAN_INFO_LOW_PASS_FILTER_3DB_FREQUENCY),
		.info_mask_separate = BIT(IIO_CHAN_INFO_RAW),
		.scan_index = ICM20948_SCAN_TEMP,
		.scan_type = ICM20948_CHAN_TYPE
	},

	ICM20948_MAG_CHAN(IIO_MAGN, IIO_MOD_X, ICM20948_SCAN_MAG_X),
	ICM20948_MAG_CHAN(IIO_MAGN, IIO_MOD_Y, ICM20948_SCAN_MAG_Y),
	ICM20948_MAG_CHAN(IIO_MAGN, IIO_MOD_Z, ICM20948_SCAN_MAG_Z),

	IIO_CHAN_SOFT_TIMESTAMP(ICM20948_SCAN_TIMESTAMP)
};

static int icm20948_i2c_probe(struct i2c_client *client)
{
	struct iio_dev *indio_dev;
	ICM20948_DATA_T *icm;
	ICM20948_BURST_DATA_T data;
	int ret, count;

	indio_dev = devm_iio_device_alloc(&client->dev, sizeof(ICM20948_DATA_T));
	if (indio_dev == NULL) {
		return -ENOMEM;
	}

	icm = iio_priv(indio_dev);
	icm->client = client;
	i2c_set_clientdata(client, indio_dev);
	mutex_init(&icm->lock);

	indio_dev->dev.parent = &client->dev;
	indio_dev->name = "icm20948";
	indio_dev->info = &icm20948_info;
	indio_dev->modes = INDIO_DIRECT_MODE;
	indio_dev->channels = icm20948_channels;
	indio_dev->num_channels = ARRAY_SIZE(icm20948_channels);
	indio_dev->available_scan_masks = icm20948_scan_masks;

	// get mount matrix (reads the "mount-matrix" DT/firmware property)
	ret = iio_read_mount_matrix(&client->dev, &icm->orientation);
	if (ret) {
		return ret;
	}

	// force register select on next access
	icm->bank_reg = 0xff;

	// check WHO_AM_I
	ret = icm20948_read_byte(icm, WHO_AM_I);
	if (ret < 0) {
		return ret;
	}
	if (ret != RV_WHO_AM_I) {
		dev_err(&client->dev, "WHO_AM_I not matching.\n");
		return -ENODEV;
	}

	// reset device
	ret = icm20948_write_byte(icm, PWR_MGMT_1, RV_DEVICE_RESET | RV_CLKSEL_0);
	if (ret < 0) {
		return ret;
	}
	msleep(ICM_RESET_TIME);
	ret = icm20948_read_byte(icm, PWR_MGMT_1);
	if (ret < 0) {
		return ret;
	}
	if ((ret & RV_DEVICE_RESET) != 0) {
		dev_err(&client->dev, "DEVICE_RESET not done.\n");
		return -ETIMEDOUT;
	}

	// get device out of sleep
	ret = icm20948_write_byte(icm, PWR_MGMT_1, RV_CLKSEL_0);
	if (ret < 0) {
		return ret;
	}

	// enable I2C Master
	ret = icm20948_write_byte(icm, USER_CTRL, RV_I2C_MST_EN);
	if (ret < 0) {
		return ret;
	}

	// Configure I2C master clock and stop/restart behaviour. The reset
	// default of 0x00 leaves the master at ~370 kHz with restart-between-
	// transactions, which both InvenSense's reference code and the upstream
	// kernel inv_mpu6050 driver explicitly override. Setting P_NSR=1 (STOP
	// between transactions) + MST_CLK=7 (~345.6 kHz) matches that practice.
	ret = icm20948_write_byte(icm, I2C_MST_CTRL,
		RV_I2C_MST_P_NSR | RV_I2C_MST_CLK(7));
	if (ret < 0) {
		return ret;
	}


	// check MAG_WIA2
	// try multiple times to recover MAG's I2C state from
	// potentialy aborted previous transfer 
	for(count = 3; count > 0; count--) {
		ret = icm20948_slave_read_byte(icm, MAG_I2C_ADDR, MAG_WIA2);
		if (ret == RV_MAG_WIA2) {
			break;
		}
	}
	if (ret < 0) {
		return ret;
	}
	if (ret != RV_MAG_WIA2) {
		dev_err(&client->dev, "MAG_WIA2 not matching.\n");
		return -ENODEV;
	}

	// reset MAG
	ret = icm20948_slave_write_byte(icm, MAG_I2C_ADDR, MAG_CNTL3, RV_MAG_SRST);
	if (ret < 0) {
		return ret;
	}
	msleep(MAG_RESET_TIME);
	ret = icm20948_slave_read_byte(icm, MAG_I2C_ADDR, MAG_CNTL3);
	if (ret < 0) {
		return ret;
	}
	if ((ret & RV_MAG_SRST) != 0) {
		dev_err(&client->dev, "MAG_SRST not done.\n");
		return -ETIMEDOUT;
	}

	// Configure the aux-master rate BEFORE enabling any slaves. Each
	// single-shot measurement takes ~7.5 ms on the AK09916, so the aux
	// rate must be slow enough that the AK09916 finishes a measurement
	// before the next trigger arrives. Otherwise the AK09916 wedges on
	// the aux bus and slave-4 reads from it start returning NACK.
	// Aux rate = gyro_rate / (SLV4_CTRL[4:0]+1); with the default ~1.1 kHz
	// gyro rate and a delay value of 10 this lands around 100 Hz (~10 ms).
	ret = icm20948_write_byte(icm, I2C_SLV4_CTRL, 10);
	if (ret < 0) {
		return ret;
	}
	ret = icm20948_write_byte(icm, I2C_MST_DELAY_CTRL,
		RV_I2C_SLV0_DLY_EN | RV_I2C_SLV1_DLY_EN);
	if (ret < 0) {
		return ret;
	}

	// Slave-0: continuously copy mag HXL..ST2 (8 bytes) into BANK_0
	// EXT_SLV_SENS_DATA_00..07. BYTE_SW reorders each big-endian word to
	// match the IMC's byte order. Reading the trailing ST2 byte releases
	// the AK09916's measurement lock so the next single-shot can fire.
	ret = icm20948_write_byte(icm, I2C_SLV0_ADDR, MAG_I2C_ADDR | I2C_SLV_ADDR_READ);
	if (ret < 0) {
		return ret;
	}
	ret = icm20948_write_byte(icm, I2C_SLV0_REG, MAG_HXL);
	if (ret < 0) {
		return ret;
	}
	ret = icm20948_write_byte(icm, I2C_SLV0_CTRL,
		RV_I2C_SLV0_EN | RV_I2C_SLV0_GRP | RV_I2C_SLV0_BYTE_SW |
		sizeof(ICM20948_MAG_DATA_T));
	if (ret < 0) {
		return ret;
	}

	// Slave-1: write CNTL2=SINGLE to the mag every aux-master cycle. The
	// AK09916 does not accept continuous-mode writes via the slave-4 path
	// (CNTL2=0x08 silently fails to latch); upstream Linux's ak8975 driver
	// uses single-measurement mode for the same reason. Slave-1 re-triggers
	// a one-shot measurement each cycle; slave-0 reads out the result on
	// the next cycle.
	ret = icm20948_write_byte(icm, I2C_SLV1_ADDR, MAG_I2C_ADDR);
	if (ret < 0) {
		return ret;
	}
	ret = icm20948_write_byte(icm, I2C_SLV1_REG, MAG_CNTL2);
	if (ret < 0) {
		return ret;
	}
	ret = icm20948_write_byte(icm, I2C_SLV1_DO, RV_MAG_MODE_SINGLE);
	if (ret < 0) {
		return ret;
	}
	ret = icm20948_write_byte(icm, I2C_SLV1_CTRL, RV_I2C_SLV1_EN | 1);
	if (ret < 0) {
		return ret;
	}

	// Give slave-1 one full aux cycle to fire and the AK09916 time to
	// complete its first measurement before we read out below.
	msleep(50);

	// try to read data (verifies the end-to-end aux path is working)
	ret = icm20948_read(icm, &data);
	if (ret < 0) {
		return ret;
	}

	ret = iio_triggered_buffer_setup(indio_dev, NULL, icm20948_trigger_handler, NULL);
	if (ret < 0) {
		dev_err(&client->dev, "IIO triggered buffer setup failed\n");
		return ret;
	}

	ret = icm20948_setup_data_rdy_trigger(indio_dev);
	if (ret < 0) {
		iio_triggered_buffer_cleanup(indio_dev);
		dev_err(&client->dev, "data-ready trigger setup failed\n");
		return ret;
	}

	ret = iio_device_register(indio_dev);
	if (ret < 0) {
		iio_triggered_buffer_cleanup(indio_dev);
		dev_err(&client->dev, "Unable to register iio device\n");
		return ret;
	}

	dev_info(&client->dev, "IIO device registered.\n");

	return 0;
}

static void icm20948_i2c_remove(struct i2c_client *client)
{
	struct iio_dev *indio_dev = i2c_get_clientdata(client);
	ICM20948_DATA_T *icm = iio_priv(indio_dev);

	iio_device_unregister(indio_dev);
	iio_triggered_buffer_cleanup(indio_dev);

	// Disable slave-0 (read) and slave-1 (mag re-trigger) before the master.
	icm20948_write_byte(icm, I2C_SLV0_CTRL, 0);
	icm20948_write_byte(icm, I2C_SLV1_CTRL, 0);
	icm20948_write_byte(icm, I2C_MST_DELAY_CTRL, 0);
	msleep(SLAVE_XFER_TIME * sizeof(ICM20948_MAG_DATA_T));

	// disable I2C Master
	icm20948_write_byte(icm, USER_CTRL, 0);
	msleep(SLAVE_XFER_TIME);

	// set device to sleep
	icm20948_write_byte(icm, PWR_MGMT_1, RV_SLEEP | RV_CLKSEL_0);
}

static const struct of_device_id icm20948_of_i2c_match[] = {
	{ .compatible = "invensense,icm20948" },
	{ },
};
MODULE_DEVICE_TABLE(of, icm20948_of_i2c_match);

static const struct i2c_device_id icm20948_i2c_id[] = {
	{ "icm20948" },
	{ },
};
MODULE_DEVICE_TABLE(i2c, icm20948_i2c_id);

static struct i2c_driver icm20948_i2c_driver = {
	.driver = {
		.name	= "icm20948",
		.of_match_table = of_match_ptr(icm20948_of_i2c_match),
	},
	.probe		= icm20948_i2c_probe,
	.remove		= icm20948_i2c_remove,
	.id_table	= icm20948_i2c_id,
};
module_i2c_driver(icm20948_i2c_driver);

MODULE_AUTHOR("Sascha Ittner <sascha.ittner@modusoft.de>");
MODULE_DESCRIPTION("Driver for ICM20948 9-Axis MEMS sensors (I2C only)");
MODULE_LICENSE("GPL v2");

