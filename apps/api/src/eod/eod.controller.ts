import {
  Body,
  Controller,
  Get,
  Param,
  Post,
  UseGuards,
} from '@nestjs/common';

import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';
import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

import { EodService } from './eod.service';
import { StartEodDto } from './dto/start-eod.dto';

@Controller('eod')
@UseGuards(AuthGuard, PermissionsGuard)
export class EodController {
  constructor(private readonly eodService: EodService) {}

  @Post('validate')
  @RequirePermissions('eod.validate')
  async validateReadiness(
    @CurrentUser() user: AuthenticatedUser,
    @Body('businessDateId') businessDateId: string,
  ) {
    return this.eodService.validateReadiness(user.tenantId, businessDateId);
  }

  @Post('start')
  @RequirePermissions('eod.execute')
  async startEodProcessing(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: StartEodDto,
  ) {
    return this.eodService.startEodProcessing(user.tenantId, dto.businessDateId, user.id);
  }

  @Post('execute-step')
  @RequirePermissions('eod.execute')
  async executeStep(
    @CurrentUser() user: AuthenticatedUser,
    @Body('batchId') batchId: string,
    @Body('stepType') stepType: string,
  ) {
    return this.eodService.executeStep(user.tenantId, batchId, stepType);
  }

  @Post('complete')
  @RequirePermissions('eod.execute')
  async completeEodProcessing(
    @CurrentUser() user: AuthenticatedUser,
    @Body('batchId') batchId: string,
  ) {
    return this.eodService.completeEodProcessing(user.tenantId, batchId);
  }

  @Post('advance-date')
  @RequirePermissions('eod.execute')
  async advanceBusinessDate(
    @CurrentUser() user: AuthenticatedUser,
    @Body('currentBusinessDateId') currentBusinessDateId: string,
  ) {
    return this.eodService.advanceBusinessDate(user.tenantId, currentBusinessDateId);
  }

  @Get('batches')
  @RequirePermissions('eod.read')
  async getBatches(@CurrentUser() user: AuthenticatedUser) {
    return this.eodService.getBatches(user.tenantId);
  }

  @Get('batches/:id')
  @RequirePermissions('eod.read')
  async getBatchDetails(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') batchId: string,
  ) {
    return this.eodService.getBatchDetails(user.tenantId, batchId);
  }
}
