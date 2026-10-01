import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
  ParseIntPipe,
  DefaultValuePipe,
} from '@nestjs/common';
import { IsString, IsNotEmpty, IsUUID, IsEnum, IsOptional } from 'class-validator';

import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';
import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

import { KycService } from './kyc.service';
import { AddKycDocumentDto } from './dto/add-kyc-document.dto';
import { VerifyDocumentDto } from './dto/verify-document.dto';
import { ClassifyRiskDto } from './dto/classify-risk.dto';

enum RestrictionType {
  DEBIT_FREEZE = 'DEBIT_FREEZE',
  CREDIT_FREEZE = 'CREDIT_FREEZE',
  FULL_FREEZE = 'FULL_FREEZE',
  WITHDRAWAL_LIMIT = 'WITHDRAWAL_LIMIT',
  NO_INTERNATIONAL = 'NO_INTERNATIONAL',
  NO_ONLINE = 'NO_ONLINE',
}

export class AddRestrictionDto {
  @IsUUID()
  @IsNotEmpty()
  customerId: string;

  @IsEnum(RestrictionType)
  @IsNotEmpty()
  restrictionType: RestrictionType;

  @IsString()
  @IsNotEmpty()
  reason: string;
}

enum WatchlistIdentifierType {
  NAME = 'NAME',
  ID_NUMBER = 'ID_NUMBER',
  PHONE = 'PHONE',
  EMAIL = 'EMAIL',
  TIN = 'TIN',
}

enum WatchlistSource {
  INTERNAL = 'INTERNAL',
  SANCTIONS = 'SANCTIONS',
  PEP = 'PEP',
  LAW_ENFORCEMENT = 'LAW_ENFORCEMENT',
  REGULATORY = 'REGULATORY',
}

export class AddWatchlistDto {
  @IsEnum(WatchlistIdentifierType)
  @IsNotEmpty()
  identifierType: WatchlistIdentifierType;

  @IsString()
  @IsNotEmpty()
  identifierValue: string;

  @IsEnum(WatchlistSource)
  @IsNotEmpty()
  listSource: WatchlistSource;

  @IsString()
  @IsOptional()
  reason?: string;
}

@Controller('kyc')
@UseGuards(AuthGuard, PermissionsGuard)
export class KycController {
  constructor(private readonly kycService: KycService) {}

  @Post('documents')
  @RequirePermissions('kyc.documents.manage')
  async addDocument(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: AddKycDocumentDto,
  ) {
    return this.kycService.addDocument(user.tenantId, dto);
  }

  @Get('documents/:customerId')
  @RequirePermissions('kyc.read')
  async getDocuments(
    @CurrentUser() user: AuthenticatedUser,
    @Param('customerId') customerId: string,
  ) {
    return this.kycService.getDocuments(user.tenantId, customerId);
  }

  @Patch('documents/:id/verify')
  @RequirePermissions('kyc.documents.manage')
  async verifyDocument(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') documentId: string,
    @Body() dto: VerifyDocumentDto,
  ) {
    return this.kycService.verifyDocument(user.tenantId, documentId, user.id, dto);
  }

  @Post('risk-classification')
  @RequirePermissions('kyc.risk.manage')
  async classifyRisk(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: ClassifyRiskDto,
  ) {
    return this.kycService.classifyRisk(user.tenantId, user.id, dto);
  }

  @Get('risk-classification/:customerId')
  @RequirePermissions('kyc.read')
  async getRiskClassification(
    @CurrentUser() user: AuthenticatedUser,
    @Param('customerId') customerId: string,
  ) {
    return this.kycService.getRiskClassification(user.tenantId, customerId);
  }

  @Post('restrictions')
  @RequirePermissions('kyc.restrictions.manage')
  async addRestriction(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: AddRestrictionDto,
  ) {
    return this.kycService.addRestriction(user.tenantId, user.id, dto);
  }

  @Delete('restrictions/:id')
  @RequirePermissions('kyc.restrictions.manage')
  async liftRestriction(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') restrictionId: string,
  ) {
    return this.kycService.liftRestriction(user.tenantId, restrictionId, user.id);
  }

  @Post('watchlist')
  @RequirePermissions('kyc.watchlist.manage')
  async addWatchlist(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: AddWatchlistDto,
  ) {
    return this.kycService.addWatchlist(user.tenantId, user.id, dto);
  }

  @Get('watchlist/check')
  @RequirePermissions('kyc.read')
  async checkWatchlist(
    @CurrentUser() user: AuthenticatedUser,
    @Query('identifierType') identifierType: string,
    @Query('identifierValue') identifierValue: string,
  ) {
    return this.kycService.checkWatchlist(user.tenantId, identifierType, identifierValue);
  }

  @Get('expiring-documents')
  @RequirePermissions('kyc.read')
  async getExpiringDocuments(
    @CurrentUser() user: AuthenticatedUser,
    @Query('daysAhead', new DefaultValuePipe(30), ParseIntPipe) daysAhead: number,
  ) {
    return this.kycService.getExpiringDocuments(user.tenantId, daysAhead);
  }

  @Get('profile-history/:customerId')
  @RequirePermissions('kyc.read')
  async getProfileHistory(
    @CurrentUser() user: AuthenticatedUser,
    @Param('customerId') customerId: string,
  ) {
    return this.kycService.getProfileHistory(user.tenantId, customerId);
  }
}
