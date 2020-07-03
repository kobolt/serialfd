#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <string.h>

#define REGISTER_AL 0
#define REGISTER_AH 1
#define REGISTER_CL 2
#define REGISTER_CH 3
#define REGISTER_DL 4
#define REGISTER_DH 5

#define SECTOR_SIZE 512
#define HEADS_PER_CYLINDER_DEFAULT 2

#define OPERATION_READ_DISK_SECTORS 0x02
#define OPERATION_WRITE_DISK_SECTORS 0x03



static uint16_t get_sectors_per_track(FILE *fh)
{
  uint16_t spt;

  fseek(fh, 24, SEEK_SET); /* Offset in Volume Boot Record. */

  if (fread(&spt, sizeof(uint16_t), 1, fh) != 1) {
    return 0; /* Error */
  }

  /* Currently handling 720K and 1.44M floppies. */
  if (spt == 9 || spt == 18) {
    return spt; /* Valid */
  }

  return 0; /* Invalid */
}



static void display_help(char *progname)
{ 
  fprintf(stderr, "Usage: %s <options>\n", progname);
  fprintf(stderr, "Options:\n"
     "  -h          Display this help and exit.\n"
     "  -d DEVICE   Use TTY DEVICE.\n"
     "  -a IMAGE    Floppy IMAGE for A:\n"
     "  -b IMAGE    Floppy IMAGE for B:\n"
     "  -H HPC      Force HPC heads per cylinder.\n"
     "  -S SPT      Force SPT sectors per track.\n"
     "  -v          Verbose debugging output.\n"
     "\n");
}



int main(int argc, char *argv[])
{
  int result = EXIT_SUCCESS;
  int i, c, arg;
  int cylinder, sector, lba;
  struct termios attr;
  unsigned char registers[6];
  int debug_output = 0;
  char *tty_device = NULL;
  int tty_fd = -1;
  FILE *fh;
  char *floppy_a_image = NULL;
  char *floppy_b_image = NULL;
  FILE *floppy_a_fh = NULL;
  FILE *floppy_b_fh = NULL;
  uint16_t floppy_a_spt = 0;
  uint16_t floppy_b_spt = 0;
  int spt = 0;
  int hpc = HEADS_PER_CYLINDER_DEFAULT;
  char *operation;

  while ((c = getopt(argc, argv, "hd:a:b:H:S:v")) != -1) {
    switch (c) {
    case 'h':
      display_help(argv[0]);
      return EXIT_SUCCESS;

    case 'd':
      tty_device = optarg;
      break;

    case 'a':
      floppy_a_image = optarg;
      break;

    case 'b':
      floppy_b_image = optarg;
      break;

    case 'H':
      hpc = atoi(optarg);
      break;

    case 'S':
      spt = atoi(optarg);
      break;

    case 'v':
      debug_output = 1;
      break;

    case '?':
    default:
      display_help(argv[0]);
      return EXIT_FAILURE;
    }
  }

  if (tty_device == NULL) {
    fprintf(stderr, "Please specify a TTY!\n");
    display_help(argv[0]);
    return EXIT_FAILURE;
  }

  if (floppy_a_image == NULL && floppy_b_image == NULL) {
    fprintf(stderr, "Please specify at least one floppy image!\n");
    display_help(argv[0]);
    return EXIT_FAILURE;
  }

  if (hpc == 0) {
    fprintf(stderr, "Invalid heads per cylinder!\n");
    return EXIT_FAILURE;
  }

  /* Open serial TTY device. */
  tty_fd = open(tty_device, O_RDWR | O_NOCTTY);
  if (tty_fd == -1) {
    fprintf(stderr, "open() on TTY device failed with errno: %d\n", errno);
    return EXIT_FAILURE;
  }

  /* Set TTY into a very raw mode. */
  memset(&attr, 0, sizeof(struct termios));
  attr.c_cflag = B9600 | CS8 | CLOCAL | CREAD;
  attr.c_cc[VMIN] = 1;

  if (tcsetattr(tty_fd, TCSANOW, &attr) == -1) {
    fprintf(stderr, "tcgetattr() on TTY device failed with errno: %d\n", errno);
    close(tty_fd);
    return EXIT_FAILURE;
  }

  /* Make sure TTY "Clear To Send" signal is set. */
  arg = TIOCM_CTS;
  if (ioctl(tty_fd, TIOCMBIS, &arg) == -1) {
    fprintf(stderr, "ioctl() on TTY device failed with errno: %d\n", errno);
    close(tty_fd);
    return EXIT_FAILURE;
  }

  /* Get information about floppy A: */
  if (floppy_a_image != NULL) {
    floppy_a_fh = fopen(floppy_a_image, "r+b");
    if (floppy_a_fh == NULL) {
      fprintf(stderr, "fopen() for floppy A: failed with errno: %d\n", errno);
      result = EXIT_FAILURE;
      goto main_end;
    }

    if (spt == 0) {
      floppy_a_spt = get_sectors_per_track(floppy_a_fh);
    } else {
      floppy_a_spt = spt;
    }
    if (floppy_a_spt == 0) {
      fprintf(stderr, "Invalid sectors per track for floppy A:\n");
      result = EXIT_FAILURE;
      goto main_end;
    }
  }

  /* Get information about floppy B: */
  if (floppy_b_image != NULL) {
    floppy_b_fh = fopen(floppy_b_image, "r+b");
    if (floppy_b_fh == NULL) {
      fprintf(stderr, "fopen() for floppy B: failed with errno: %d\n", errno);
      result = EXIT_FAILURE;
      goto main_end;
    }

    if (spt == 0) {
      floppy_b_spt = get_sectors_per_track(floppy_b_fh);
    } else {
      floppy_b_spt = spt;
    }
    if (floppy_b_spt == 0) {
      fprintf(stderr, "Invalid sectors per track for floppy B:\n");
      result = EXIT_FAILURE;
      goto main_end;
    }
  }

  /* Process input and output. */
  while (1) {
    for (i = 0; i < 6; i++) {
      if (read(tty_fd, &registers[i], sizeof(unsigned char)) != 1) {
        fprintf(stderr, "read() failed with errno: %d\n", errno);
        result = EXIT_FAILURE;
        goto main_end;
      }
    }

    if (debug_output) {
      fprintf(stderr, "AL: 0x%02x\n", registers[REGISTER_AL]);
      fprintf(stderr, "AH: 0x%02x\n", registers[REGISTER_AH]);
      fprintf(stderr, "CL: 0x%02x\n", registers[REGISTER_CL]);
      fprintf(stderr, "CH: 0x%02x\n", registers[REGISTER_CH]);
      fprintf(stderr, "DL: 0x%02x\n", registers[REGISTER_DL]);
      fprintf(stderr, "DH: 0x%02x\n", registers[REGISTER_DH]);
    }

    if (registers[REGISTER_DL] == 0x00) {
      spt = floppy_a_spt;
      fh = floppy_a_fh;
    } else if (registers[REGISTER_DL] == 0x01) {
      spt = floppy_b_spt;
      fh = floppy_b_fh;
    } else {
      fprintf(stderr, "Error: Invalid drive number: %02x\n",
        registers[REGISTER_DL]);
      result = EXIT_FAILURE;
      goto main_end;
    }

    /* CX =       ---CH--- ---CL---
     * cylinder : 76543210 98
     * sector   :            543210
     * LBA = ( ( cylinder * HPC + head ) * SPT ) + sector - 1
    */

    cylinder = ((registers[REGISTER_CL] & 0xc0) << 2)
      + registers[REGISTER_CH];
    sector = registers[REGISTER_CL] & 0x3f;
    lba = ((cylinder * hpc + registers[REGISTER_DH]) * spt) + sector - 1;

    if (debug_output) {
      fprintf(stderr, "Cylinder: %d\n", cylinder);
      fprintf(stderr, "Sector  : %d\n", sector);
      fprintf(stderr, "SPT     : %d\n", spt);
      fprintf(stderr, "HPC     : %d\n", hpc);
      fprintf(stderr, "LBA     : %d\n", lba);
      fprintf(stderr, "Offset  : 0x%x\n", lba * SECTOR_SIZE);
    } else {
      switch (registers[REGISTER_AH]) {
      case OPERATION_READ_DISK_SECTORS:
        operation = "Read";
        break;
      case OPERATION_WRITE_DISK_SECTORS:
        operation = "Write";
        break;
      default:
        operation = "Unknown";
        break;
      }
      fprintf(stderr, "%s %c: sector=%d, cylinder=%d count=%d\n",
        operation, (registers[REGISTER_DL] == 0x00) ? 'A' : 'B',
        sector, cylinder, registers[REGISTER_AL]);
    }

    if (fh != NULL) {
      if (fseek(fh, lba * SECTOR_SIZE, SEEK_SET) == -1) {
        fprintf(stderr, "fseek() failed with errno: %d\n", errno);
        result = EXIT_FAILURE;
        goto main_end;
      }
    }

    switch (registers[REGISTER_AH]) {
    case OPERATION_READ_DISK_SECTORS:
      if (debug_output) {
        fprintf(stderr, "READ SECTOR DATA:\n");
      }
      for (i = 0; i < (SECTOR_SIZE * registers[REGISTER_AL]); i++) {
        if (fh != NULL) {
          c = fgetc(fh);
        } else {
          c = 0xFF; /* Dummy data if image is not loaded. */
        }
        if (debug_output) {
          fprintf(stderr, "%02x ", c);
          if (i % 16 == 15) {
            fprintf(stderr, "\n");
          }
        }
        write(tty_fd, &c, sizeof(unsigned char));
      }
      break;

    case OPERATION_WRITE_DISK_SECTORS:
      if (debug_output) {
        fprintf(stderr, "WRITE SECTOR DATA:\n");
      }
      for (i = 0; i < (SECTOR_SIZE * registers[REGISTER_AL]); i++) {
        read(tty_fd, &c, sizeof(unsigned char));
        if (fh != NULL) {
          fputc(c, fh);
        }
        if (debug_output) {
          fprintf(stderr, "%02x ", c);
          if (i % 16 == 15) {
            fprintf(stderr, "\n");
          }
        }
      }
      if (fh != NULL) {
        fflush(fh);
      }
      break;

    default:
      fprintf(stderr, "Error: Unhandled operation: %02x\n",
        registers[REGISTER_AH]);
      result = EXIT_FAILURE;
      goto main_end;
    }
  }

main_end:
  if (tty_fd != -1) close(tty_fd);
  if (floppy_a_fh != NULL) fclose(floppy_a_fh);
  if (floppy_b_fh != NULL) fclose(floppy_b_fh);

  return result;
}



